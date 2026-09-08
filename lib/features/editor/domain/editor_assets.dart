/// A local, application-owned page. It never serves workspace files.
final class EditorPage {
  const EditorPage(this.uri, this.token, this.profileDirectory);
  final Uri uri;
  final String token;
  final String profileDirectory;
}

abstract interface class EditorAssets {
  Future<EditorPage> open();
  Future<void> close();
}
