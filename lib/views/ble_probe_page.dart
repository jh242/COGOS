// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/material.dart';

class BleProbePage extends StatefulWidget {
  const BleProbePage({super.key});

  @override
  _BleProbePageState createState() => _BleProbePageState();
}

class _BleProbePageState extends State<BleProbePage> {
  final List<String> _log = [];
  StreamSubscription<String>? _sub;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _sub = BleManager.get().bleEventStream.listen((event) {
      setState(() => _log.insert(0, event));
    });
    _log.add('Listening for BLE events...');
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _probe(int cmd) async {
    if (_sending) return;
    final hex = '0x${cmd.toRadixString(16).padLeft(2, '0').toUpperCase()}';
    setState(() {
      _sending = true;
      _log.insert(0, '→ Sending [$hex] ...');
    });
    try {
      final resp = await Proto.probeSend(cmd);
      setState(() => _log.insert(0, '← [$hex] $resp'));
    } finally {
      setState(() => _sending = false);
    }
  }

  void _clearLog() => setState(() => _log.clear());

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('BLE Probe'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearLog,
              tooltip: 'Clear log',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Send unknown commands and watch the log for responses.\n'
                'Also shows all incoming 0xF5 events in real time.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _probeButton('Send 0x39', 0x39),
                  const SizedBox(width: 8),
                  _probeButton('Send 0x50', 0x50),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: _log.isEmpty
                      ? const Center(
                          child: Text(
                            'No events yet.',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        )
                      : ListView.builder(
                          reverse: false,
                          itemCount: _log.length,
                          itemBuilder: (ctx, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              _log[i],
                              style: const TextStyle(
                                color: Color(0xFF00FF88),
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _probeButton(String label, int cmd) => Expanded(
        child: GestureDetector(
          onTap: _sending ? null : () => _probe(cmd),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: _sending ? Colors.grey.shade300 : Colors.white,
              borderRadius: BorderRadius.circular(5),
            ),
            alignment: Alignment.center,
            child: Text(label, style: const TextStyle(fontSize: 14)),
          ),
        ),
      );
}
