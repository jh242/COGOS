import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _apiKeyController = TextEditingController();
  final _relayUrlController = TextEditingController();
  final _relaySecretController = TextEditingController();
  final _weatherKeyController = TextEditingController();
  final _newsKeyController = TextEditingController();
  double _silenceThreshold = 2.0;
  double _headUpAngle = 30.0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _apiKeyController.text = prefs.getString('anthropic_api_key') ?? '';
    _relayUrlController.text =
        prefs.getString('relay_url') ?? 'http://localhost:9090';
    _relaySecretController.text = prefs.getString('relay_secret') ?? '';
    _weatherKeyController.text = prefs.getString('openweather_api_key') ?? '';
    _newsKeyController.text = prefs.getString('news_api_key') ?? '';
    final threshold = (prefs.getInt('silence_threshold') ?? 2).toDouble();
    final angle = (prefs.getInt('head_up_angle') ?? 30).toDouble();
    if (mounted) setState(() {
      _silenceThreshold = threshold;
      _headUpAngle = angle;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('anthropic_api_key', _apiKeyController.text.trim());
    await prefs.setString('relay_url', _relayUrlController.text.trim());
    await prefs.setString('relay_secret', _relaySecretController.text.trim());
    await prefs.setString('openweather_api_key', _weatherKeyController.text.trim());
    await prefs.setString('news_api_key', _newsKeyController.text.trim());
    await prefs.setInt('silence_threshold', _silenceThreshold.round());
    await prefs.setInt('head_up_angle', _headUpAngle.round());
    EvenAI.get.silenceThresholdSecs = _silenceThreshold.round();
    await Proto.setHeadUpAngle(_headUpAngle.round());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _relayUrlController.dispose();
    _relaySecretController.dispose();
    _weatherKeyController.dispose();
    _newsKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: [
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Anthropic API Key',
                  hintText: 'sk-ant-...',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _relayUrlController,
                decoration: const InputDecoration(
                  labelText: 'Relay URL',
                  hintText: 'http://localhost:9090',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _relaySecretController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Relay Secret',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _weatherKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'OpenWeatherMap API Key',
                  hintText: 'For glance weather data',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _newsKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'NewsAPI Key',
                  hintText: 'For glance news headlines',
                ),
              ),
              const SizedBox(height: 24),
              Text('Silence Threshold: ${_silenceThreshold.round()}s'),
              Slider(
                value: _silenceThreshold,
                min: 1,
                max: 5,
                divisions: 4,
                label: '${_silenceThreshold.round()}s',
                onChanged: (value) =>
                    setState(() => _silenceThreshold = value),
              ),
              const SizedBox(height: 16),
              Text('Head-Up Angle: ${_headUpAngle.round()}°'),
              Slider(
                value: _headUpAngle,
                min: 10,
                max: 60,
                divisions: 10,
                label: '${_headUpAngle.round()}°',
                onChanged: (value) =>
                    setState(() => _headUpAngle = value),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _saveSettings,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
}
