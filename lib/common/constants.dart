import 'package:flutter/material.dart';
import 'package:get/get.dart';

const String kAppName = "Hikari Novel";

const String kLatestUrl = "https://api.github.com/repos/dhrw444/hikari_novel_flutter/releases/latest"; //指向本仓库 release，自建节点分发用

/// 浏览器 UA：WebView 登录、图片加载、Dio 请求三处必须完全一致
/// （Cloudflare 会校验 UA 与 cf_clearance 的绑定关系）
const String kBrowserUserAgent =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Mobile Safari/537.36";

const Map<String, String> kUserAgent = {"User-Agent": kBrowserUserAgent};

/// Dio 请求头：Cloudflare 机器人判定所需的浏览器特征头。
///
/// 实测（直连 www.wenku8.net）：只带 User-Agent、或只带 Referer 时，站内深层接口
/// （toplist.php / reader.php / search.php …）返回 403 + `cf-mitigated: challenge`；
/// 补上 sec-fetch-* 后即可直连源站正常取数据，无需 cf_clearance、无需伪造 TLS 指纹。
/// 三个 sec-fetch 头任意一个单独出现即可通过，这里保留三件套以更贴近真实浏览器。
/// Referer / Origin 由 _BrowserHeaderInterceptor 按目标域名动态补全。
const Map<String, String> kBrowserHeaders = {
  "User-Agent": kBrowserUserAgent,
  "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
  "sec-fetch-site": "same-origin",
  "sec-fetch-mode": "cors",
  "sec-fetch-dest": "empty",
};

const String kReleasesPageUrl = "https://github.com/dhrw444/hikari_novel_flutter/releases/latest"; //release 页面，浏览器下载兜底

/// 全局请求头：UA 与浏览器特征头（sec-ch-ua / sec-fetch-*）需成套出现，
/// 只有 UA 单头会被 Cloudflare 判定为爬虫，直连节点返回 403 + "Just a moment"。
/// 不要手写 Accept-Encoding / Host，Dart HttpClient 会自动处理。
///
/// sec-fetch-site 取 same-origin（与上游 ed3e880 一致）：Cloudflare 要求 reader.php
/// 这类接口看起来像站内页面发起，none 会被判为「直接访问 = 爬虫」。
/// Referer 由 _RefererInterceptor 按请求 URI 逐请求补 `{scheme}://{host}/`。
/// 实测（www.wenku8.net，HTTP/1.1 与 HTTP/2 结果一致）：
///   无 Referer          → site=none / same-origin 均 403
///   带本站 Referer      → site=none / same-origin 均 200（reader.php 35.9KB 正文）
///   → Referer 是硬条件，same-origin 是语义正确的加强项（上游同值）。
const Map<String, String> kHeader = {
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
  "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
  "sec-ch-ua": '"Microsoft Edge";v="135", "Chromium";v="135", "Not:A-Brand";v="24"',
  "sec-ch-ua-mobile": "?0",
  "sec-ch-ua-platform": '"Windows"',
  "sec-fetch-dest": "document",
  "sec-fetch-mode": "navigate",
  "sec-fetch-site": "same-origin",
  "sec-fetch-user": "?1",
  "upgrade-insecure-requests": "1",
};

const int kStatusBarPadding = 30;

const double kSmallIconSize = 16.0;

final TextStyle kBaseTileTitleTextStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w500);

final TextStyle kBaseTileSubtitleTextStyle = TextStyle(fontSize: 13);

const double kCardBorderRadius = 6.0;

const EdgeInsets kCommentAndReplyCardPadding = EdgeInsets.fromLTRB(20, 16, 20, 16);

final TextStyle kCommentAndReplyUsernameTextStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Theme.of(Get.context!).colorScheme.primary);

const int kScrollReadMode = 1;

const int kPageReadMode = 2;
