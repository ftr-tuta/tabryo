import '../domain/collaboration.dart';

Json _string({int max = 8000}) => {
  'type': 'string',
  'minLength': 1,
  'maxLength': max,
};
Json _tool(
  String name,
  String description,
  Json properties,
  List<String> required, {
  bool readOnly = true,
}) => {
  'name': name,
  'description': description,
  'inputSchema': {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  },
  'annotations': {
    'readOnlyHint': readOnly,
    'destructiveHint': false,
    'idempotentHint': true,
    'openWorldHint': false,
  },
};

final collaborationTools = [
  _tool(
    'participants',
    'List members of your group, their objective, ownership and state. Identity is bound by your connection.',
    {},
    [],
  ),
  _tool(
    'messages',
    'Read group messages after an integer cursor. Reading never wakes agents. Acknowledge your received IDs with acknowledge.',
    {
      'after': {'type': 'integer', 'minimum': 0},
    },
    [],
  ),
  _tool(
    'send',
    'Persist a summary for another group participant. Use a stable client_id to retry safely. Information never starts idle work; requests and dependency_ready may start work only if the user enabled it for the recipient.',
    {
      'recipient': _string(max: 128),
      'client_id': _string(max: 128),
      'summary': _string(),
      'kind': {
        'type': 'string',
        'enum': ['information', 'request', 'dependency_ready'],
      },
      'checkpoint_id': {'type': 'integer', 'minimum': 1},
    },
    ['recipient', 'client_id', 'summary', 'kind'],
    readOnly: false,
  ),
  _tool(
    'acknowledge',
    'Confirm receipt of a message addressed to you. Does not call a model or send another message.',
    {
      'id': {'type': 'integer', 'minimum': 1},
    },
    ['id'],
    readOnly: false,
  ),
  _tool(
    'publish_checkpoint',
    'Publish a versioned progress checkpoint. Git revision and local changes are recorded by Tabryo; validations are your reported results. Send its reference when collaborators need it.',
    {
      'client_id': _string(max: 128),
      'summary': _string(max: 2000),
      for (final key in [
        'objective',
        'state',
        'decisions',
        'review',
        'validation',
        'next_step',
      ])
        key: _string(),
    },
    [
      'client_id',
      'summary',
      'objective',
      'state',
      'decisions',
      'review',
      'validation',
      'next_step',
    ],
    readOnly: false,
  ),
  _tool(
    'checkpoints',
    'List checkpoint summaries in your group; use checkpoint_detail to load detail when needed.',
    {
      'author': _string(max: 128),
      'after': {'type': 'integer', 'minimum': 0},
    },
    [],
  ),
  _tool(
    'checkpoint_detail',
    'Read a specific checkpoint, including version, local Git state, decisions and reported validation.',
    {
      'id': {'type': 'integer', 'minimum': 1},
    },
    ['id'],
  ),
];

void validateToolArguments(String name, Json values) {
  final schema = collaborationTools.where((t) => t['name'] == name).firstOrNull;
  if (schema == null) {
    throw const CollaborationFailure('Unknown collaboration tool.');
  }
  final input = schema['inputSchema'] as Map;
  final props = input['properties'] as Map;
  if (values.keys.any((key) => !props.containsKey(key))) {
    throw const CollaborationFailure(
      'Unexpected tool argument. Sender and group are supplied by the connection.',
    );
  }
  for (final key in input['required'] as List) {
    if (!values.containsKey(key)) throw CollaborationFailure('Missing $key.');
  }
  for (final entry in values.entries) {
    final property = props[entry.key] as Map;
    if (property['type'] == 'string') {
      requiredText(
        values,
        entry.key,
        max: (property['maxLength'] as int?) ?? 8000,
      );
    }
    if (property['type'] == 'integer' &&
        (entry.value is! int ||
            (entry.value as int) < (property['minimum'] as int))) {
      throw CollaborationFailure('Invalid ${entry.key}.');
    }
    if (property['enum'] is List &&
        !(property['enum'] as List).contains(entry.value)) {
      throw CollaborationFailure('Invalid ${entry.key}.');
    }
  }
}
