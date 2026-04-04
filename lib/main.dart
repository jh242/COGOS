
import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/controllers/evenai_model_controller.dart';
import 'package:demo_ai_even/services/glance_service.dart';
import 'package:demo_ai_even/services/notification_service.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:demo_ai_even/views/home_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final ble = BleManager.get();
  Get.put(EvenaiModelController());

  await NotificationService.get.init();
  GlanceService.get.init();

  ble.onStatusChanged = () async {
    if (ble.isConnected) {
      NotificationService.get.pushWhitelistToGlasses();
      final prefs = await SharedPreferences.getInstance();
      final angle = prefs.getInt('head_up_angle') ?? 30;
      await Proto.setHeadUpAngle(angle);
    }
  };

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Even AI Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: HomePage(),
    );
  }
}
