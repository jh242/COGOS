class ClaudeSession {
  String? relaySessionId;
  bool isOffline = false;
  final List<Map<String, String>> messages;
  String? lastQuery;
  String? lastAnswer;

  ClaudeSession() : messages = [];

  void addUser(String text) => messages.add({'role': 'user', 'content': text});
  void addAssistant(String text) =>
      messages.add({'role': 'assistant', 'content': text});

  void reset() {
    relaySessionId = null;
    messages.clear();
    isOffline = false;
    lastQuery = null;
    lastAnswer = null;
  }

  static const int maxTurns = 20;
}
