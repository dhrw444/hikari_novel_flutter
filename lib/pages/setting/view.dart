import 'dart:io';

import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/models/common/language.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/pages/setting/controller.dart';
import 'package:hikari_novel_flutter/widgets/custom_tile.dart';
import 'package:jiffy/jiffy.dart';

import '../../service/local_storage_service.dart';

class SettingPage extends StatelessWidget {
  SettingPage({super.key});

  final controller = Get.put(SettingController());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("setting".tr), titleSpacing: 0),
      body: Column(
        children: [
          Obx(() {
            final sub = switch (controller.language.value) {
              Language.followSystem => "follow_system".tr,
              Language.simplifiedChinese => "简体中文",
              Language.traditionalChinese => "繁體中文",
            };
            return NormalTile(
              title: "language".tr,
              subtitle: sub,
              leading: const Icon(Icons.language),
              onTap: () =>
                  showRadioListSheet(
                    context,
                    value: controller.language.value,
                    values: [(Language.followSystem, "follow_system".tr), (Language.simplifiedChinese, "简体中文"), (Language.traditionalChinese, "繁體中文")],
                    title: "language".tr,
                  ).then((value) async {
                    if (value != null) controller.changeLanguage(value);
                  }),
            );
          }),
          Obx(() {
            final sub = switch (controller.themeMode.value) {
              ThemeMode.system => "follow_system".tr,
              ThemeMode.light => "light_mode".tr,
              ThemeMode.dark => "dark_mode".tr,
            };
            return NormalTile(
              title: "theme_mode".tr,
              subtitle: sub,
              leading: const Icon(Icons.palette_outlined),
              onTap: () =>
                  showRadioListSheet(
                    context,
                    value: controller.themeMode.value,
                    values: [(ThemeMode.system, "follow_system".tr), (ThemeMode.light, "light_mode".tr), (ThemeMode.dark, "dark_mode".tr)],
                    title: "theme_mode".tr,
                  ).then((value) {
                    if (value != null) controller.changeThemeMode(value);
                  }),
            );
          }),
          Offstage(
            offstage: !Platform.isAndroid,
            child: Obx(
              () => SwitchTile(
                title: "dynamic_color_mode".tr,
                leading: const Icon(Icons.colorize),
                onChanged: (value) => controller.changeIsDynamicColor(value),
                value: controller.isDynamicColor.value,
              ),
            ),
          ),
          Offstage(
            offstage: controller.isDynamicColor.value && Platform.isAndroid,
            child: Obx(
              () => NormalTile(
                title: "theme_color".tr,
                leading: const Icon(Icons.format_color_fill_outlined),
                trailing: ColorIndicator(width: 28, height: 28, borderRadius: 100, color: controller.customColor.value),
                onTap: () => _buildColorPickerDialog(context),
              ),
            ),
          ),
          Obx(() {
            return NormalTile(
              title: "node".tr,
              subtitle: controller.wenku8Node.value.node,
              leading: const Icon(Icons.lan_outlined),
              onTap: () => _showNodeSheet(context),
            );
          }),
          Obx(
            () => SwitchTile(
              title: "relative_time".tr,
              subtitle: "relative_time_tip".trParams({
                "relativeTime": Jiffy.parse(DateTime.parse("2026-01-25 16:27:00").toString()).fromNow().toString(),
                "normalTime": "2026-01-25 16:27:00",
              }),
              leading: const Icon(Icons.access_time_outlined),
              onChanged: (v) => controller.changeIsRelativeTime(v),
              value: controller.isRelativeTime.value,
            ),
          ),
          Obx(
            () => SwitchTile(
              title: "auto_check_update".tr,
              leading: const Icon(Icons.update),
              onChanged: (v) => controller.changeIsAutoCheckUpdate(v),
              value: controller.isAutoCheckUpdate.value,
            ),
          ),
        ],
      ),
    );
  }

  void _buildColorPickerDialog(BuildContext context) async {
    final initColor = LocalStorageService.instance.getCustomColor();
    final newColor = await showColorPickerDialog(
      context,
      initColor,
      showMaterialName: true,
      showColorName: true,
      showColorCode: true,
      materialNameTextStyle: Theme.of(context).textTheme.bodySmall,
      colorNameTextStyle: Theme.of(context).textTheme.bodySmall,
      colorCodeTextStyle: Theme.of(context).textTheme.bodySmall,
      pickersEnabled: const <ColorPickerType, bool>{
        ColorPickerType.both: false,
        ColorPickerType.primary: true,
        ColorPickerType.accent: false,
        ColorPickerType.bw: false,
        ColorPickerType.custom: true,
        ColorPickerType.wheel: false,
      },
      pickerTypeLabels: <ColorPickerType, String>{ColorPickerType.primary: "theme_color".tr, ColorPickerType.wheel: "custom".tr},
      enableShadesSelection: false,
      actionButtons: ColorPickerActionButtons(dialogOkButtonLabel: "save".tr, dialogCancelButtonLabel: "cancel".tr),
      copyPasteBehavior: ColorPickerCopyPasteBehavior().copyWith(copyFormat: ColorPickerCopyFormat.hexRRGGBB),
    );
    if (newColor == initColor) return;
    controller.changeCustomColor(newColor);
  }

  void _showNodeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) {
        final titleLarge = Theme.of(context).textTheme.titleLarge!;
        final titleMedium = Theme.of(context).textTheme.titleMedium!;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 0, 10),
                child: Text("node".tr, style: titleLarge.copyWith(fontWeight: FontWeight.bold)),
              ),
              Obx(() => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final n in Wenku8Node.builtins)
                    RadioListTile<Wenku8Node>(
                      value: n,
                      groupValue: controller.wenku8Node.value,
                      title: Text(n.node, style: titleMedium),
                      onChanged: (_) {
                        controller.changeWenku8Node(n);
                        Navigator.of(context).pop();
                      },
                    ),
                  for (final url in controller.customNodes)
                    RadioListTile<Wenku8Node>(
                      value: Wenku8Node.custom(url),
                      groupValue: controller.wenku8Node.value,
                      title: Text(url, style: titleMedium),
                      secondary: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => controller.removeCustomNode(url),
                      ),
                      onChanged: (_) {
                        controller.changeWenku8Node(Wenku8Node.custom(url));
                        Navigator.of(context).pop();
                      },
                    ),
                ],
              )),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text("add_custom_node".tr, style: titleMedium),
                onTap: () => _showAddNodeDialog(context),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  void _showAddNodeDialog(BuildContext context) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("add_custom_node".tr),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: "https://your-proxy.example.com",
            labelText: "node_url".tr,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text("cancel".tr)),
          TextButton(
            onPressed: () {
              final input = textController.text.trim();
              if (input.isNotEmpty) {
                this.controller.addCustomNode(input);
                Navigator.of(context).pop();
              }
            },
            child: Text("save".tr),
          ),
        ],
      ),
    );
  }
}
