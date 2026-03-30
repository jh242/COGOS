// ignore_for_file: library_private_types_in_public_api

import 'package:demo_ai_even/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  _NotificationSettingsPageState createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  List<String> _whitelist = [];
  final TextEditingController _addCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _whitelist = List.from(NotificationService.get.whitelist);
  }

  @override
  void dispose() {
    _addCtl.dispose();
    super.dispose();
  }

  Future<void> _addApp() async {
    final id = _addCtl.text.trim();
    if (id.isEmpty || _whitelist.contains(id)) return;
    final updated = [..._whitelist, id];
    await NotificationService.get.setWhitelist(updated);
    setState(() {
      _whitelist = updated;
      _addCtl.clear();
    });
  }

  Future<void> _removeApp(String id) async {
    final updated = _whitelist.where((e) => e != id).toList();
    await NotificationService.get.setWhitelist(updated);
    setState(() => _whitelist = updated);
  }

  Future<void> _pushToGlasses() async {
    await NotificationService.get.pushWhitelistToGlasses();
    Fluttertoast.showToast(msg: 'Whitelist pushed to glasses');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Notification Settings')),
        body: Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'App whitelist (empty = all apps)',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _whitelist.isEmpty
                    ? const Center(
                        child: Text(
                          'No apps in whitelist.\nAll notifications will be forwarded.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _whitelist.length,
                        itemBuilder: (ctx, i) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: ListTile(
                            title: Text(_whitelist[i],
                                style: const TextStyle(fontSize: 14)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red),
                              onPressed: () => _removeApp(_whitelist[i]),
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _addCtl,
                        decoration: const InputDecoration.collapsed(
                            hintText: 'com.example.app'),
                        style: const TextStyle(fontSize: 14),
                        onSubmitted: (_) => _addApp(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _addApp,
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      alignment: Alignment.center,
                      child:
                          const Text('Add', style: TextStyle(fontSize: 14)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _pushToGlasses,
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: const Text('Push whitelist to glasses',
                      style: TextStyle(fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      );
}
