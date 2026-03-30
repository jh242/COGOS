import 'dart:async';
import 'dart:convert';

import 'package:demo_ai_even/models/claude_session.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RelayOfflineException implements Exception {
  final String message;
  RelayOfflineException([this.message = 'Relay unreachable']);
}

class RelayAuthException implements Exception {
  final String message;
  RelayAuthException([this.message = 'Relay authentication failed']);
}

class CoworkRelayService {
  Stream<String> queryStream(String message, ClaudeSession session) async* {
    final prefs = await SharedPreferences.getInstance();
    final relayUrl = prefs.getString('relay_url') ?? 'http://localhost:9090';
    final relaySecret = prefs.getString('relay_secret') ?? '';

    final body = <String, dynamic>{
      'message': message,
      if (session.relaySessionId != null) 'session_id': session.relaySessionId,
    };

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: Duration.zero,
      headers: {
        'Accept': 'text/event-stream',
        'Content-Type': 'application/json',
        if (relaySecret.isNotEmpty) 'Authorization': 'Bearer $relaySecret',
      },
    ));

    Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        '$relayUrl/query',
        data: body,
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) throw RelayAuthException();
      throw RelayOfflineException(e.message ?? 'Network error');
    }

    final stream = response.data!.stream;
    final buffer = StringBuffer();

    await for (final chunk in stream) {
      buffer.write(utf8.decode(chunk));
      final raw = buffer.toString();
      final lines = raw.split('\n');
      buffer.clear();
      buffer.write(lines.last);

      for (final line in lines.sublist(0, lines.length - 1)) {
        if (!line.startsWith('data:')) continue;
        final jsonStr = line.substring(5).trim();
        if (jsonStr.isEmpty) continue;

        final Map<String, dynamic> event;
        try {
          event = jsonDecode(jsonStr) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final type = event['type'] as String?;
        if (type == 'text') {
          final text = event['text'] as String? ?? '';
          if (text.isNotEmpty) yield text;
        } else if (type == 'done') {
          final sid = event['session_id'] as String?;
          if (sid != null) session.relaySessionId = sid;
          return;
        } else if (type == 'error') {
          throw Exception('Relay error: ${event['message']}');
        }
      }
    }
  }
}
