import 'dart:async';
import 'dart:convert';

import 'package:demo_ai_even/models/claude_session.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiClaudeService {
  static const String _systemPrompt =
      'You are a helpful assistant on Even Realities G1 smart glasses. '
      'The display shows 5 lines at a time. Be concise. No markdown.';

  Stream<String> streamChatRequest(
      String message, ClaudeSession session) async* {
    const envKey = String.fromEnvironment('ANTHROPIC_API_KEY');
    final apiKey = envKey.isNotEmpty
        ? envKey
        : (await SharedPreferences.getInstance()).getString('anthropic_api_key') ?? '';

    final allMessages = [
      ...session.messages,
      {'role': 'user', 'content': message},
    ];
    final cappedMessages = allMessages.length > ClaudeSession.maxTurns
        ? allMessages.sublist(allMessages.length - ClaudeSession.maxTurns)
        : allMessages;

    final body = {
      'model': 'claude-sonnet-4-6',
      'max_tokens': 1024,
      'stream': true,
      'system': _systemPrompt,
      'messages': cappedMessages,
    };

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: Duration.zero,
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
    ));

    Response<ResponseBody> response;
    try {
      response = await dio.post<ResponseBody>(
        'https://api.anthropic.com/v1/messages',
        data: body,
        options: Options(responseType: ResponseType.stream),
      );
    } on DioException catch (e) {
      throw Exception('Claude API error: ${e.message}');
    }

    final stream = response.data!.stream;
    final buffer = StringBuffer();
    String? currentEvent;

    await for (final chunk in stream) {
      buffer.write(utf8.decode(chunk));
      final raw = buffer.toString();
      final lines = raw.split('\n');
      buffer.clear();
      buffer.write(lines.last);

      for (final line in lines.sublist(0, lines.length - 1)) {
        if (line.startsWith('event:')) {
          currentEvent = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          if (currentEvent != 'content_block_delta') continue;
          final jsonStr = line.substring(5).trim();
          if (jsonStr.isEmpty || jsonStr == '[DONE]') continue;

          final Map<String, dynamic> event;
          try {
            event = jsonDecode(jsonStr) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }

          final delta = event['delta'] as Map<String, dynamic>?;
          if (delta?['type'] == 'text_delta') {
            final text = delta!['text'] as String? ?? '';
            if (text.isNotEmpty) yield text;
          }
        } else if (line.isEmpty) {
          currentEvent = null;
        }
      }
    }
  }
}
