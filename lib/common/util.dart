import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/models/resource.dart';
import 'package:hikari_novel_flutter/service/local_storage_service.dart';
import 'package:jiffy/jiffy.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/common/language.dart';
import '../service/api_service.dart';
import 'constants.dart';
import 'log.dart';

class Util {
  static String getDateTime(String dateStr) {
    if (!LocalStorageService.instance.getIsRelativeTime()) {
      return dateStr;
    }
    final DateTime inputDate = DateTime.parse(dateStr);
    return Jiffy.parse(inputDate.toString()).fromNow();
  }

  static Locale getCurrentLocale() {
    final language = LocalStorageService.instance.getLanguage();
    if (language == Language.followSystem) {
      if (Get.deviceLocale == Locale("zh", "CN")) {
        return Locale("zh", "CN");
      } else if (Get.deviceLocale == Locale("zh", "TW")) {
        return Locale("zh", "TW");
      } else {
        return Locale("zh", "CN");
      }
    }
    return switch (language) {
      Language.simplifiedChinese => Locale("zh", "CN"),
      Language.traditionalChinese => Locale("zh", "TW"),
      _ => Locale("zh", "CN"),
    };
  }

  /// 复用 MainActivity 中已有的 hikari/system_intents 通道唤起系统安装器
  static const MethodChannel _intentChannel = MethodChannel("hikari/system_intents");

  /// 已下载的 APK 路径：用于「安装未知应用」授权后二次点击直接安装，避免重复下载
  static String? _pendingApkPath;

  /// 已下载 APK 对应的文件名，防止缓存与新版本错配（例如下载后未安装，release 又更新了）
  static String? _pendingApkName;

  /// 归一化版本号：去掉可选的 v/V 前缀与 +build 后缀（"v0.5.0-beta.1+13" -> "0.5.0-beta.1"）
  static String normalizeVersion(String version) {
    return version.trim().replaceFirst(RegExp(r"^[vV]"), "").split("+").first.trim();
  }

  /// 解析 build number（"+" 之后那段，即 versionCode），
  /// 兼容 "v0.5.0-beta.2+15" 与纯数字 "15" 两种入参，解析失败返回 0
  static int parseBuildNumber(String version) {
    final raw = version.trim().replaceFirst(RegExp(r"^[vV]"), "");
    final tail = raw.contains("+") ? raw.split("+").last : raw;
    return int.tryParse(tail.trim()) ?? 0;
  }

  /// 检查更新。
  /// [mustNotification] 为 true 表示用户手动检查，此时即使没有新版本也会给出提示；
  /// 为 false 表示启动时的自动检查，只在确实存在新版本时才弹窗。
  static Future<void> checkUpdate(bool mustNotification) async {
    try {
      final response = await ApiService.instance.fetchLatestRelease();
      if (response is! Success) {
        if (mustNotification) _showSimpleDialog("check_update".tr, response.error.toString());
        return;
      }

      final data = response.data;
      final String remoteTag = (data["tag_name"] ?? "").toString(); // e.g. "v0.5.0-beta.2+15"
      final String remoteVer = normalizeVersion(remoteTag); // "0.5.0-beta.2"
      final int remoteBuild = parseBuildNumber(remoteTag); // 15

      //PackageInfo 的版本名与 build number 分属两个字段，需分开取
      final packageInfo = await PackageInfo.fromPlatform();
      final String localVer = normalizeVersion(packageInfo.version);
      final int localBuild = parseBuildNumber(packageInfo.buildNumber);

      //版本名不同即有新版；版本名相同再比 build number（仅 bump +N 也算新版）
      final bool hasNewVersion = remoteVer.isNotEmpty && (remoteVer != localVer || remoteBuild > localBuild);

      //不需要通知且没有新版本，直接返回
      if (!mustNotification && !hasNewVersion) return;

      if (!hasNewVersion) {
        if (mustNotification) _showSimpleDialog("check_update".tr, "no_new_version_available".tr);
        return;
      }

      // 从 release 附件中找 APK 直链（CI 会把 apk 作为 asset 上传）
      String? apkUrl;
      String apkFileName = "hikari_novel_$remoteVer.apk";
      final assets = data["assets"];
      if (assets is List) {
        for (final asset in assets) {
          final String name = (asset["name"] ?? "").toString();
          if (name.toLowerCase().endsWith(".apk")) {
            apkFileName = name;
            apkUrl = asset["browser_download_url"]?.toString();
            break;
          }
        }
      }
      final String pageUrl = (data["html_url"] ?? kReleasesPageUrl).toString();

      Get.dialog(
        AlertDialog(
          title: Text("check_update".tr),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("${"new_version_available".tr}: $remoteTag", style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 8),
                if ((data["body"] ?? "").toString().isNotEmpty) MarkdownBlock(data: data["body"]),
              ],
            ),
          ),
          actions: [
            // 方式一：App 内下载 + 唤起系统安装器
            TextButton(
              onPressed: () {
                Get.back();
                _startInstallFlow(apkUrl: apkUrl, pageUrl: pageUrl, fileName: apkFileName);
              },
              child: Text("builtin_update".tr),
            ),
            // 方式二：交给浏览器/外部下载器
            TextButton(
              onPressed: () {
                Get.back();
                _openInBrowser(pageUrl);
              },
              child: Text("browser_download".tr),
            ),
            TextButton(onPressed: () => Get.back(), child: Text("cancel".tr)),
          ],
        ),
      );
    } catch (e, s) {
      // 网络异常、GitHub API 不可达、返回结构变化等都不应该让用户无感知或崩溃
      Log.e("checkUpdate failed: $e\n$s");
      if (mustNotification) _showSimpleDialog("check_update".tr, e.toString());
    }
  }

  /// 内置更新流程：若之前已下载过则直接重试安装，否则先下载再安装
  static Future<void> _startInstallFlow({String? apkUrl, required String pageUrl, required String fileName}) async {
    final String? cached = _pendingApkPath;
    if (cached != null && cached.isNotEmpty && _pendingApkName == fileName) {
      // 返回 true 表示安装包已不存在，需要重新下载
      final bool needRedownload = await _installApk(cached);
      if (!needRedownload) return;
      _pendingApkPath = null;
      _pendingApkName = null;
    }

    if (apkUrl == null || apkUrl.isEmpty) {
      // release 未附带 APK 时兜底交给浏览器打开 release 页
      await _openInBrowser(pageUrl);
      return;
    }

    final dir = await getTemporaryDirectory();
    final String savePath = "${dir.path}/$fileName";

    // 清理历史遗留在缓存目录里的安装包（保留待安装的那一个，避免堆积）
    try {
      await for (final entity in dir.list()) {
        final String name = entity.path.split("/").last;
        if (name.startsWith("hikari_novel_") && name.endsWith(".apk") && entity.path != _pendingApkPath) {
          await entity.delete();
        }
      }
    } catch (e) {
      Log.e("clean old apk failed: $e");
    }
    final progress = 0.0.obs;

    Get.dialog(
      PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text("downloading".tr),
          content: Obx(
            () => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: progress.value <= 0 ? null : progress.value),
                const SizedBox(height: 10),
                Text("${(progress.value * 100).toStringAsFixed(1)}%"),
              ],
            ),
          ),
        ),
      ),
      barrierDismissible: false,
    );

    try {
      //独立 Dio：ApiClient 的 dio 是 followRedirects:false + CF 拦截器，不能用于 GitHub 附件下载
      final dio = Dio(
        BaseOptions(
          headers: kHeader,
          followRedirects: true,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
      await dio.download(
        apkUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0) progress.value = received / total;
        },
      );
    } catch (e, s) {
      Log.e("download apk failed: $e\n$s");
      _closeDialog();
      _showSimpleDialog("download_failed".tr, e.toString());
      return;
    }
    _closeDialog();

    _pendingApkPath = savePath;
    _pendingApkName = fileName;
    if (await _installApk(savePath)) {
      // 极端情况：下载完成到唤起安装器之间安装包被系统清理掉，提示用户重试
      _showSimpleDialog("install_failed".tr, "download_failed".tr);
    }
  }

  /// 唤起系统安装器安装 APK：返回 true 表示安装包不可用、上层需重新下载，
  /// 返回 false 表示已成功唤起安装器，或已给出授权/失败提示
  static Future<bool> _installApk(String path) async {
    try {
      final result = await _intentChannel.invokeMethod("installApk", {"path": path});
      if (result == "need_permission") {
        //原生侧已跳转「安装未知应用」设置页，授权后重试即可
        _showSimpleDialog("install_failed".tr, "install_unknown_source_tip".tr);
        return false;
      }
      return false;
    } on PlatformException catch (e) {
      //FILE_NOT_FOUND：安装包已被系统清理，返回 true 让上层重新下载
      if (e.code == "FILE_NOT_FOUND") return true;
      Log.e("installApk failed: ${e.code} ${e.message}");
      _showSimpleDialog("install_failed".tr, e.message ?? e.code);
      return false;
    } catch (e) {
      Log.e("installApk failed: $e");
      _showSimpleDialog("install_failed".tr, e.toString());
      return false;
    }
  }

  /// 打开外部浏览器（release 未附带 APK 时的浏览器下载兜底）
  static Future<void> _openInBrowser(String url) async {
    try {
      final bool ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok) _showSimpleDialog("unable_to_open_external_browser".tr, url);
    } catch (e) {
      _showSimpleDialog("unable_to_open_external_browser".tr, e.toString());
    }
  }

  /// 关闭当前的更新相关对话框，可重复调用
  static void _closeDialog() {
    if (Get.isDialogOpen ?? false) Get.back();
  }

  /// 简易纯文本提示框（错误信息等，不渲染 Markdown）
  static void _showSimpleDialog(String title, String content) {
    Get.dialog(
      AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [TextButton(onPressed: () => Get.back(), child: Text("confirm".tr))],
      ),
    );
  }
}
