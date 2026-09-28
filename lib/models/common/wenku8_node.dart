enum Wenku8Node { wwwWenku8Net, wwwWenku8Cc, proxyWorker }

extension Wenku8NodeDesc on Wenku8Node {
  String get node => ["https://www.wenku8.net", "https://www.wenku8.cc", "https://dhr.kdns.fr"][index];
}
