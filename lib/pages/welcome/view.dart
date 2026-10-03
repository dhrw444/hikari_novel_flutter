import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/pages/welcome/controller.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';
import 'package:hikari_novel_flutter/widgets/state_page.dart';
import '../../models/common/wenku8_node.dart';

class WelcomePage extends StatelessWidget {
  WelcomePage({super.key});

  final controller = Get.put(WelcomeController());

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LogoPage(),
            const SizedBox(height: 20),
            Text("welcome_to_use_app".tr, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text("welcome_tip".tr, style: TextStyle(fontSize: 14)),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: () => Get.toNamed(RoutePath.login), label: Text("go_to_login".tr), icon: const Icon(Icons.login)),
            const SizedBox(height: 40),
            GetBuilder<WelcomeController>(
              builder: (_) => PopupMenuButton<String>(
                onSelected: (String value) {
                  if (value == "__add_custom__") {
                    _showAddNodeDialog(context);
                    return;
                  }
                  controller.changeWenku8Node(Wenku8Node.custom(value));
                },
                itemBuilder: (BuildContext context) => [
                  for (final n in Wenku8Node.builtins)
                    PopupMenuItem<String>(
                      value: n.url,
                      child: Text(
                        n.node,
                        style: controller.wenku8Node == n ? TextStyle(color: primaryColor, fontWeight: FontWeight.bold) : null,
                      ),
                    ),
                  for (final url in controller.customNodes)
                    PopupMenuItem<String>(
                      value: url,
                      child: Text(
                        url,
                        style: controller.wenku8Node.url == url ? TextStyle(color: primaryColor, fontWeight: FontWeight.bold) : null,
                      ),
                    ),
                  PopupMenuItem<String>(
                    value: "__add_custom__",
                    child: Row(
                      children: [
                        Icon(Icons.add, size: 18, color: primaryColor),
                        SizedBox(width: 8),
                        Text("add_custom_node".tr, style: TextStyle(color: primaryColor)),
                      ],
                    ),
                  ),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lan_outlined, size: 16, color: primaryColor),
                    SizedBox(width: 8),
                    Text("node".tr, style: TextStyle(color: primaryColor)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
                controller.addCustomNode(input);
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
