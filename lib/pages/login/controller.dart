import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/main.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/page_state.dart';
import 'package:hikari_novel_flutter/common/constants.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';
import 'package:hikari_novel_flutter/service/api_service.dart';

import '../../common/database/database.dart';
import '../../models/resource.dart';
import '../../parser/parser.dart';
import '../../service/db_service.dart';
import '../../service/local_storage_service.dart';

class LoginController extends GetxController {
  RxBool showLoading = true.obs;
  RxInt loadingProgress = 0.obs;
  final CookieManager cookieManager = CookieManager.instance(webViewEnvironment: webViewEnvironment);
  InAppWebViewController? inAppWebViewController;
  final GlobalKey webViewKey = GlobalKey();
  final InAppWebViewSettings settings = InAppWebViewSettings(isInspectable: kDebugMode, userAgent: kUserAgent["User-Agent"], javaScriptEnabled: true);
  RxString currentUrl = "".obs;

  Rx<PageState> pageState = PageState.success.obs;
  String errorMsg = "";

  String get url => "${ApiService.instance.wenku8Node.node}/login.php";

  @override
  void onInit() {
    super.onInit();
    cookieManager.deleteAllCookies();
  }

  Future<void> saveCookie(WebUri uri) async {
    showLoading.value = false;

    // 按当前节点的 host 匹配，兼容官方域名与任意代理域名
    final nodeHost = Uri.parse(ApiService.instance.wenku8Node.node).host;
    if (uri.host != nodeHost) return;

    // 优先从 WebView 内部用 JS 读 document.cookie（比 CookieManager API 更可靠），失败再回退 CookieManager
    final cookieMap = await _readCookies(uri);
    if (cookieMap == null) return;

    if (!cookieMap.containsKey("jieqiUserInfo") || !cookieMap.containsKey("jieqiVisitInfo")) return;

    String cookie = "jieqiUserInfo=${cookieMap['jieqiUserInfo']};";
    cookie += "jieqiVisitInfo=${cookieMap['jieqiVisitInfo']}";
    // cf_clearance 一并保存，API 请求时可复用 WebView 已通过 CF 盾的凭据
    final cfClearance = cookieMap['cf_clearance'];
    if (cfClearance != null && cfClearance.isNotEmpty) {
      cookie += ";cf_clearance=$cfClearance";
    }
    await _onLoginSuccess(cookie);
  }

  Future<Map<String, String>?> _readCookies(WebUri uri) async {
    final controller = inAppWebViewController;
    if (controller != null) {
      try {
        final raw = (await controller.evaluateJavascript(source: "document.cookie"))?.toString() ?? "";
        final map = <String, String>{};
        for (final part in raw.split(';')) {
          final trimmed = part.trim();
          final eq = trimmed.indexOf('=');
          if (eq > 0) map[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
        }
        if (map.isNotEmpty) return map;
      } catch (_) {}
    }
    final cookies = await cookieManager.getCookies(url: uri);
    if (cookies.isEmpty) return null;
    return {for (final c in cookies) c.name: c.value};
  }

  Future<void> _onLoginSuccess(String cookie) async {
    LocalStorageService.instance.setCookie(cookie);
    ApiService.instance.initCookie();

    try {
      await _getUserInfo();
      await _refreshBookshelf();
    } catch (e) {
      LocalStorageService.instance.setCookie(null); //清空cookie
      ApiService.instance.deleteCookie();

      final controller = inAppWebViewController;
      if (controller != null) {
        inAppWebViewController = null;
        controller.dispose(); //销毁webview，停止加载网页
      }

      errorMsg = e.toString();
      pageState.value = PageState.error;

      return;
    }

    Get.offAllNamed(RoutePath.main);
  }

  Future<void> _getUserInfo() async {
    final data = await ApiService.instance.getUserInfo();
    switch (data) {
      case Success():
        LocalStorageService.instance.setUserInfo(Parser.getUserInfo(data.data));
      case Error():
        {
          throw data.error;
        }
    }
  }

  Future<void> _refreshBookshelf() async {
    await DBService.instance.deleteAllBookshelf();

    final futures = Iterable.generate(6, (index) async {
      await _insertAll(index);
    });
    await Future.wait(futures);
  }

  Future<void> _insertAll(int index) async {
    final result = await ApiService.instance.getBookshelf(classId: index);
    switch (result) {
      case Success():
        {
          final bookshelf = Parser.getBookshelf(result.data, index);
          if (bookshelf.list.isNotEmpty) {
            final insertData = bookshelf.list.map((e) {
              return BookshelfEntityData(aid: e.aid, bid: e.bid, url: e.url, title: e.title, img: e.img, classId: bookshelf.classId.toString());
            });
            await DBService.instance.insertAllBookshelf(insertData);
          }
        }
      case Error():
        {
          throw result.error;
        }
    }
  }
}
