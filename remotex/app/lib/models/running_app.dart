/// One open window on the PC, as listed by the server.
class RunningApp {
  const RunningApp({required this.id, required this.title, required this.exe, required this.iconId, required this.foreground});

  final int id;
  final String title;
  final String exe;
  final String iconId;
  final bool foreground;

  static RunningApp? tryParse(Object? v) {
    if (v is! Map) return null;
    final id = v['id'];
    if (id is! int) return null;
    final title = v['title'];
    final exe = v['exe'];
    final ic = v['ic'];
    return RunningApp(
      id: id,
      title: title is String ? title : '',
      exe: exe is String ? exe : '',
      iconId: ic is String ? ic : '',
      foreground: v['fg'] == true,
    );
  }
}
