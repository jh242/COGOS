

import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/glance_service.dart';

class App {
  static App? _instance;
  static App get get => _instance ??= App._();

  App._();

  // exit features by receiving [oxf5 0]
  void exitAll({bool isNeedBackHome = true}) async {
    GlanceService.get.dismiss();
    if (EvenAI.isEvenAIOpen.value) {
      await EvenAI.get.stopEvenAIByOS();
    }
  }
}