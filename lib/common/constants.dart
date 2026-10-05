import 'package:flutter/material.dart';
import 'package:get/get.dart';

const String kAppName = "Hikari Novel";

const String kLatestUrl = "https://api.github.com/repos/dhrw444/hikari_novel_flutter/releases/latest"; //指向本仓库 release，自建节点分发用

const String kReleasesPageUrl = "https://github.com/dhrw444/hikari_novel_flutter/releases/latest"; //release 页面，浏览器下载兜底

/// 全局请求头：UA 与浏览器特征头（sec-ch-ua / sec-fetch-*）需成套出现，
/// 只有 UA 单头会被 Cloudflare 判定为爬虫，直连节点返回 403 + "Just a moment"。
/// 不要手写 Accept-Encoding / Host / Referer，Dart HttpClient 会自动处理。
const Map<String, String> kHeader = {
  "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
  "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
  "sec-ch-ua": '"Microsoft Edge";v="135", "Chromium";v="135", "Not:A-Brand";v="24"',
  "sec-ch-ua-mobile": "?0",
  "sec-ch-ua-platform": '"Windows"',
  "sec-fetch-dest": "document",
  "sec-fetch-mode": "navigate",
  "sec-fetch-site": "none",
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
