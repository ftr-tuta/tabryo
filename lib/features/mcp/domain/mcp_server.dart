enum McpTransport { stdio, streamableHttp }

final class McpServer {
  McpServer({
    required this.name,
    required this.configuration,
    required this.origin,
    required this.editable,
    this.tools = const {},
    this.resources = const [],
    this.authStatus = 'unknown',
    this.status = 'Not connected',
  });
  final String name;
  final Map<String, Object?> configuration;
  final String origin;
  final bool editable;
  final Map<String, Object?> tools;
  final List<Map<String, Object?>> resources;
  final String authStatus;
  final String status;
  bool get enabled => configuration['enabled'] != false;
  bool get http => configuration['url'] is String;
}

final class McpConfigChange {
  const McpConfigChange({
    required this.filePath,
    required this.expectedVersion,
    required this.edits,
    required this.description,
    required this.preview,
  });
  final String filePath;
  final String expectedVersion;
  final List<Map<String, Object?>> edits;
  final String description;
  final String preview;
}

final class McpServerDraft {
  const McpServerDraft({
    required this.name,
    required this.transport,
    this.command,
    this.arguments,
    this.workingDirectory,
    this.url,
    this.environmentNames,
    this.bearerEnvironmentName,
  });
  final String name;
  final McpTransport transport;
  final String? command;
  final List<String>? arguments;
  final String? workingDirectory;
  final String? url;
  final List<String>? environmentNames;
  final String? bearerEnvironmentName;
}
