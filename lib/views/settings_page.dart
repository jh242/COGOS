import 'package:demo_ai_even/services/evenai.dart';
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
  double _silenceThreshold = 2.0;

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
    final threshold = (prefs.getInt('silence_threshold') ?? 2).toDouble();
    if (mounted) setState(() => _silenceThreshold = threshold);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('anthropic_api_key', _apiKeyController.text.trim());
    await prefs.setString('relay_url', _relayUrlController.text.trim());
    await prefs.setString('relay_secret', _relaySecretController.text.trim());
    await prefs.setInt('silence_threshold', _silenceThreshold.round());
    EvenAI.get.silenceThresholdSecs = _silenceThreshold.round();
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
