enum LoopKind { appointment, deadline }

enum LoopState { open, needsInput, closed }

enum RetentionPolicy { immediately, sevenDays, thirtyDays, keep }

class LoopChecklistItem {
  const LoopChecklistItem({
    required this.id,
    required this.title,
    this.completed = false,
    this.isRequired = true,
  });
  final String id;
  final String title;
  final bool completed;
  final bool isRequired;

  LoopChecklistItem copyWith({bool? completed}) => LoopChecklistItem(
    id: id,
    title: title,
    completed: completed ?? this.completed,
    isRequired: isRequired,
  );

  factory LoopChecklistItem.fromJson(Map<String, dynamic> json) =>
      LoopChecklistItem(
        id: json['id'] as String,
        title: json['title'] as String,
        completed: json['completed'] as bool? ?? false,
        isRequired: json['required'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'completed': completed,
    'required': isRequired,
  };
}

class OpenLoop {
  const OpenLoop({
    required this.id,
    required this.kind,
    required this.state,
    required this.title,
    required this.source,
    required this.createdAt,
    required this.confidence,
    this.date,
    this.time,
    this.place,
    this.purpose,
    this.summary,
    this.participants = const [],
    this.resolutionNote,
    this.missingFields = const [],
    this.reminderOffsets = const [],
    this.actions = const [],
    this.checklist = const [],
    this.checkpoints = const [],
    this.completedAt,
    this.deleteAt,
  });

  final String id;
  final LoopKind kind;
  final LoopState state;
  final String title;
  final String source;
  final DateTime createdAt;
  final DateTime? date;
  final String? time;
  final String? place;
  final String? purpose;
  final String? summary;
  final List<String> participants;
  final String? resolutionNote;
  final List<String> missingFields;
  final List<String> reminderOffsets;
  final List<LoopAction> actions;
  final List<LoopChecklistItem> checklist;
  final List<LoopCheckpoint> checkpoints;
  final DateTime? completedAt;
  final DateTime? deleteAt;
  final Map<String, double> confidence;

  DateTime? get startsAt {
    if (date == null) return null;
    final parts = time?.split(':');
    return DateTime(
      date!.year,
      date!.month,
      date!.day,
      parts == null ? 9 : int.tryParse(parts.first) ?? 9,
      parts == null || parts.length < 2 ? 0 : int.tryParse(parts[1]) ?? 0,
    );
  }

  OpenLoop copyWith({
    LoopState? state,
    String? title,
    DateTime? date,
    String? time,
    String? place,
    String? purpose,
    String? summary,
    List<String>? participants,
    List<String>? missingFields,
    List<LoopAction>? actions,
    List<LoopChecklistItem>? checklist,
    List<LoopCheckpoint>? checkpoints,
    DateTime? completedAt,
    DateTime? deleteAt,
  }) => OpenLoop(
    id: id,
    kind: kind,
    state: state ?? this.state,
    title: title ?? this.title,
    source: source,
    createdAt: createdAt,
    date: date ?? this.date,
    time: time ?? this.time,
    place: place ?? this.place,
    purpose: purpose ?? this.purpose,
    summary: summary ?? this.summary,
    participants: participants ?? this.participants,
    resolutionNote: resolutionNote,
    missingFields: missingFields ?? this.missingFields,
    reminderOffsets: reminderOffsets,
    actions: actions ?? this.actions,
    checklist: checklist ?? this.checklist,
    checkpoints: checkpoints ?? this.checkpoints,
    completedAt: completedAt ?? this.completedAt,
    deleteAt: deleteAt ?? this.deleteAt,
    confidence: confidence,
  );

  factory OpenLoop.fromAnalyzeJson(Map<String, dynamic> json) {
    final event = json['event'] as Map<String, dynamic>? ?? const {};
    final dateText = event['date'] as String?;
    final confidenceJson =
        event['confidence'] as Map<String, dynamic>? ?? const {};
    final reminders = event['reminders'] as List<dynamic>? ?? const [];
    return OpenLoop(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      kind: event['type'] == 'deadline'
          ? LoopKind.deadline
          : LoopKind.appointment,
      state: switch (json['status']) {
        'closed' => LoopState.closed,
        'needs_input' => LoopState.needsInput,
        _ => LoopState.open,
      },
      title: event['title'] as String? ?? '새 Open Loop',
      source: event['source'] as String? ?? 'text',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      date: dateText == null ? null : DateTime.tryParse(dateText),
      time: event['start_time'] as String?,
      place: (event['place'] as Map<String, dynamic>?)?['name'] as String?,
      purpose: event['purpose'] as String?,
      summary: event['summary'] as String?,
      participants: List<String>.from(
        event['participants'] as List<dynamic>? ?? const [],
      ),
      resolutionNote: event['resolution_note'] as String?,
      missingFields: List<String>.from(
        event['missing_fields'] as List<dynamic>? ?? const [],
      ),
      reminderOffsets: reminders
          .map((item) => (item as Map<String, dynamic>)['offset'] as String?)
          .whereType<String>()
          .toList(),
      actions: (json['actions'] as List<dynamic>? ?? const [])
          .map((item) => LoopAction.fromJson(item as Map<String, dynamic>))
          .toList(),
      checklist:
          (json['checklist'] as List<dynamic>? ??
                  event['checklist'] as List<dynamic>? ??
                  const [])
              .map(
                (item) =>
                    LoopChecklistItem.fromJson(item as Map<String, dynamic>),
              )
              .toList(),
      checkpoints: (json['checkpoints'] as List<dynamic>? ?? const [])
          .map((item) => LoopCheckpoint.fromJson(item as Map<String, dynamic>))
          .toList(),
      completedAt: json['completed_at'] == null
          ? null
          : DateTime.tryParse(json['completed_at'] as String),
      deleteAt: json['delete_at'] == null
          ? null
          : DateTime.tryParse(json['delete_at'] as String),
      confidence: confidenceJson.map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      ),
    );
  }

  factory OpenLoop.fromJson(Map<String, dynamic> json) => OpenLoop(
    id: json['id'] as String,
    kind: LoopKind.values.byName(json['kind'] as String),
    state: LoopState.values.byName(json['state'] as String),
    title: json['title'] as String,
    source: json['source'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    date: json['date'] == null ? null : DateTime.parse(json['date'] as String),
    time: json['time'] as String?,
    place: json['place'] as String?,
    purpose: json['purpose'] as String?,
    summary: json['summary'] as String?,
    participants: List<String>.from(
      json['participants'] as List<dynamic>? ?? const [],
    ),
    resolutionNote: json['resolutionNote'] as String?,
    missingFields: List<String>.from(
      json['missingFields'] as List<dynamic>? ?? const [],
    ),
    reminderOffsets: List<String>.from(
      json['reminderOffsets'] as List<dynamic>? ?? const [],
    ),
    actions: (json['actions'] as List<dynamic>? ?? const [])
        .map((item) => LoopAction.fromJson(item as Map<String, dynamic>))
        .toList(),
    checklist: (json['checklist'] as List<dynamic>? ?? const [])
        .map((item) => LoopChecklistItem.fromJson(item as Map<String, dynamic>))
        .toList(),
    checkpoints: (json['checkpoints'] as List<dynamic>? ?? const [])
        .map((item) => LoopCheckpoint.fromJson(item as Map<String, dynamic>))
        .toList(),
    completedAt: json['completedAt'] == null
        ? null
        : DateTime.tryParse(json['completedAt'] as String),
    deleteAt: json['deleteAt'] == null
        ? null
        : DateTime.parse(json['deleteAt'] as String),
    confidence: (json['confidence'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(key, (value as num).toDouble()),
    ),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'state': state.name,
    'title': title,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    'date': date?.toIso8601String(),
    'time': time,
    'place': place,
    'purpose': purpose,
    'summary': summary,
    'participants': participants,
    'resolutionNote': resolutionNote,
    'missingFields': missingFields,
    'reminderOffsets': reminderOffsets,
    'actions': actions.map((item) => item.toJson()).toList(),
    'checklist': checklist.map((item) => item.toJson()).toList(),
    'checkpoints': checkpoints.map((item) => item.toJson()).toList(),
    'completedAt': completedAt?.toIso8601String(),
    'deleteAt': deleteAt?.toIso8601String(),
    'confidence': confidence,
  };
}

class LoopAction {
  const LoopAction({
    required this.id,
    required this.type,
    required this.title,
    this.completed = false,
    this.metadata = const {},
  });
  final String id;
  final String type;
  final String title;
  final bool completed;
  final Map<String, dynamic> metadata;

  LoopAction copyWith({bool? completed, Map<String, dynamic>? metadata}) =>
      LoopAction(
        id: id,
        type: type,
        title: title,
        completed: completed ?? this.completed,
        metadata: metadata ?? this.metadata,
      );

  factory LoopAction.fromJson(Map<String, dynamic> json) => LoopAction(
    id: json['id'] as String,
    type: json['type'] as String,
    title: json['title'] as String,
    completed: json['completed'] as bool? ?? false,
    metadata: Map<String, dynamic>.from(
      json['metadata'] as Map? ?? const <String, dynamic>{},
    ),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'completed': completed,
    'metadata': metadata,
  };
}

class LoopCheckpoint {
  const LoopCheckpoint({
    required this.id,
    required this.offset,
    required this.title,
    this.dueAt,
    this.completed = false,
  });

  final String id;
  final String offset;
  final String title;
  final DateTime? dueAt;
  final bool completed;

  LoopCheckpoint copyWith({bool? completed}) => LoopCheckpoint(
    id: id,
    offset: offset,
    title: title,
    dueAt: dueAt,
    completed: completed ?? this.completed,
  );

  factory LoopCheckpoint.fromJson(Map<String, dynamic> json) => LoopCheckpoint(
    id: json['id'] as String,
    offset: json['offset'] as String,
    title: json['title'] as String,
    dueAt: json['due_at'] == null
        ? null
        : DateTime.tryParse(json['due_at'] as String),
    completed: json['completed'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'offset': offset,
    'title': title,
    'due_at': dueAt?.toIso8601String(),
    'completed': completed,
  };
}
