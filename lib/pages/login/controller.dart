import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/main.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/custom_exception.dart';
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
  final InAppWebViewSettings settings = InAppWebViewSettings(isInspectable: kDebugMode, userAgent: kHeader["User-Agent"], javaScriptEnabled: true);

  /// 桌面指纹伪装：Android WebView 改不了 Sec-CH-UA 头，CF 挑战会读 navigator 指纹交叉校验，
  /// 此处把 JS 可读指纹统一成 Windows 桌面与 kHeader 一致，避免被判定机器人而拦截登录。
  static const String _desktopFingerprintScript = """
(function() {
  var brands = [
    {brand: 'Microsoft Edge', version: '135'},
    {brand: 'Chromium', version: '135'},
    {brand: 'Not:A-Brand', version: '24'}
  ];
  var fullBrands = [
    {brand: 'Microsoft Edge', version: '135.0.0.0'},
    {brand: 'Chromium', version: '135.0.0.0'},
    {brand: 'Not:A-Brand', version: '24.0.0.0'}
  ];
  var uaData = {
    brands: brands,
    mobile: false,
    platform: 'Windows',
    getHighEntropyValues: function(hints) {
      return Promise.resolve({
        architecture: 'x86',
        bitness: '64',
        brands: brands,
        fullVersionList: fullBrands,
        mobile: false,
        model: '',
        platform: 'Windows',
        platformVersion: '15.0.0',
        uaFullVersion: '135.0.0.0',
        wow64: false
      });
    },
    toJSON: function() { return {brands: brands, mobile: false, platform: 'Windows'}; }
  };
  var defs = [
    ['userAgentData', function() { return uaData; }],
    ['platform', function() { return 'Win32'; }],
    ['vendor', function() { return 'Google Inc.'; }],
    ['maxTouchPoints', function() { return 0; }],
    ['hardwareConcurrency', function() { return 8; }],
    ['deviceMemory', function() { return 8; }]
  ];
  defs.forEach(function(d) {
    try { Object.defineProperty(navigator, d[0], {get: d[1], configurable: true}); } catch (e) {}
  });
})();
""";

  /// 文档开始即注入（含 iframe，CF 挑战可能在 iframe 里跑）
  final UnmodifiableListView<UserScript> initialUserScripts = UnmodifiableListView([
    UserScript(source: _desktopFingerprintScript, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
  ]);

  RxString currentUrl = "".obs;

  Rx<PageState> pageState = PageState.success.obs;
  String errorMsg = "";

  String get url => "${ApiService.instance.wenku8Node.node}/login.php";

  @override
  void onInit() {
    super.onInit();
    cookieManager.deleteAllCookies();
  }

  bool _handlingLogin = false; //防重入：onLoadStop 对加载完成的每个页面都会触发一次

  /// WebView 加载完成回调：提取 cookie 并落盘；仅当前节点域名生效，cookie 缺失或不合法时不写入
  Future<void> saveCookie(WebUri uri) async {
    showLoading.value = false;

    //按当前节点的 host 匹配，兼容官方域名与任意代理域名
    final nodeHost = Uri.parse(ApiService.instance.wenku8Node.node).host;
    if (!uri.toString().contains("wenku8") && uri.host != nodeHost) return;
    if (_handlingLogin) return;
    _handlingLogin = true;
    try {
      var cookieMap = await _readCookies(uri);
      if (cookieMap == null) return;
      if (!cookieMap.containsKey("jieqiUserInfo") || !cookieMap.containsKey("jieqiVisitInfo")) return;

      //cf_clearance 是 CF 挑战通过后异步下发的，刚登录完可能尚未落库，读不到就稍等重读
      for (var i = 0; i < 3; i++) {
        final cf = cookieMap?['cf_clearance'];
        if (cf != null && cf.isNotEmpty) break;
        await Future.delayed(const Duration(milliseconds: 800));
        final fresh = await _readCookies(uri);
        if (fresh != null) cookieMap = {...?cookieMap, ...fresh};
      }

      String cookie = "jieqiUserInfo=${cookieMap!['jieqiUserInfo']};";
      cookie += "jieqiVisitInfo=${cookieMap['jieqiVisitInfo']}";
      //cf_clearance 一并保存，API 请求时可复用 WebView 已通过 CF 盾的凭据
      final cfClearance = cookieMap['cf_clearance'];
      if (cfClearance != null && cfClearance.isNotEmpty) {
        cookie += ";cf_clearance=$cfClearance";
      }
      await _onLoginSuccess(cookie);
    } finally {
      _handlingLogin = false;
    }
  }

  /// 读取 cookie：CookieManager 优先（cf_clearance 是 HttpOnly，document.cookie 读不到），
  /// JS 结果作补充，两路合并都为空时返回 null
  Future<Map<String, String>?> _readCookies(WebUri uri) async {
    final map = <String, String>{};

    // CookieManager 读原生 cookie 库，含 HttpOnly 的 cf_clearance
    final cookies = await cookieManager.getCookies(url: uri);
    for (final c in cookies) {
      if (c.name.isNotEmpty) map[c.name] = c.value;
    }

    // JS 回退/补充（只能拿到非 HttpOnly cookie）
    final controller = inAppWebViewController;
    if (controller != null) {
      try {
        final raw = (await controller.evaluateJavascript(source: "document.cookie"))?.toString() ?? "";
        for (final part in raw.split(';')) {
          final trimmed = part.trim();
          final eq = trimmed.indexOf('=');
          if (eq > 0) map[trimmed.substring(0, eq)] ??= trimmed.substring(eq + 1);
        }
      } catch (_) {}
    }

    return map.isEmpty ? null : map;
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
