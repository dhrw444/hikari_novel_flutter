class Wenku8Node {
  final String url;
  final bool isBuiltin;

  const Wenku8Node._(this.url, this.isBuiltin);

  static const wwwWenku8Net = Wenku8Node._("https://www.wenku8.net", true);
  static const wwwWenku8Cc = Wenku8Node._("https://www.wenku8.cc", true);

  static const List<Wenku8Node> builtins = [wwwWenku8Net, wwwWenku8Cc];

  String get node => url;

  factory Wenku8Node.custom(String input) {
    var u = input.trim();
    if (u.isEmpty) u = "https://";
    if (!u.startsWith("http://") && !u.startsWith("https://")) u = "https://$u";
    while (u.endsWith("/")) u = u.substring(0, u.length - 1);
    return Wenku8Node._(u, false);
  }

  @override
  bool operator ==(Object other) => other is Wenku8Node && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => url;
}
