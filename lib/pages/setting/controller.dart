import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/models/common/language.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';

import '../../service/local_storage_service.dart';

class SettingController extends GetxController {
  RxBool isAutoCheckUpdate = LocalStorageService.instance.getIsAutoCheckUpdate().obs;
  Rx<Language> language = Rx(LocalStorageService.instance.getLanguage());
  RxBool isRelativeTime = LocalStorageService.instance.getIsRelativeTime().obs;
  Rx<Wenku8Node> wenku8Node = Rx(LocalStorageService.instance.getWenku8Node());
  RxList<String> customNodes = LocalStorageService.instance.getCustomNodes().obs;
  Rx<ThemeMode> themeMode = Rx(LocalStorageService.instance.getThemeMode());
  RxBool isDynamicColor = LocalStorageService.instance.getIsDynamicColor().obs;
  Rx<Color> customColor = Rx(LocalStorageService.instance.getCustomColor());

  void changeIsAutoCheckUpdate(bool enabled) {
    isAutoCheckUpdate.value = enabled;
    LocalStorageService.instance.setIsAutoCheckUpdate(enabled);
  }

  void changeIsRelativeTime(bool enabled) {
    isRelativeTime.value = enabled;
    LocalStorageService.instance.setIsRelativeTime(enabled);
  }

  void changeLanguage(Language l) async {
    switch (l) {
      case Language.simplifiedChinese:
        Get.updateLocale(Locale("zh", "CN"));
      case Language.traditionalChinese:
        Get.updateLocale(Locale("zh", "TW"));
      case Language.followSystem:
        {
          if (Get.deviceLocale! != Locale("zh", "CN") && Get.deviceLocale! != Locale("zh", "CN")) {
            Get.updateLocale(Locale("zh", "CN"));
          } else {
            Get.updateLocale(Get.deviceLocale!);
          }
        }
    }
    language.value = l;
    LocalStorageService.instance.setLanguage(l);
  }

  void changeWenku8Node(Wenku8Node n) {
    wenku8Node.value = n;
    LocalStorageService.instance.setWenku8Node(n);
  }

  void addCustomNode(String url) {
    final node = Wenku8Node.custom(url);
    LocalStorageService.instance.addCustomNode(node.url);
    customNodes.value = LocalStorageService.instance.getCustomNodes();
    changeWenku8Node(node);
  }

  void removeCustomNode(String url) {
    LocalStorageService.instance.removeCustomNode(url);
    customNodes.value = LocalStorageService.instance.getCustomNodes();
    if (wenku8Node.value.url == url) {
      changeWenku8Node(Wenku8Node.wwwWenku8Cc);
    }
  }

  void changeCustomColor(Color color) {
    customColor.value = color;
    LocalStorageService.instance.setCustomColor(color);
    Get.forceAppUpdate();
  }

  void changeIsDynamicColor(bool enabled) {
    isDynamicColor.value = enabled;
    LocalStorageService.instance.setIsDynamicColor(enabled);
    Get.forceAppUpdate();
  }

  void changeThemeMode(ThemeMode mode) {
    themeMode.value = mode;
    LocalStorageService.instance.setThemeMode(mode);
    Get.forceAppUpdate();
  }
}
