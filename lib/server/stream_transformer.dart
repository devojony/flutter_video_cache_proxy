import 'dart:async';
import 'dart:math';

class ChunkedStreamTransformer<T> implements StreamTransformer<List<T>, List<T>> {
  final int chunkSize;

  ChunkedStreamTransformer(this.chunkSize);

  @override
  Stream<List<T>> bind(Stream<List<T>> stream) async* {
    var buffer = <T>[];
    await for (var element in stream) {
      final ls = List.of(element);
      while (ls.isNotEmpty) {
        const start = 0;
        final end = min(chunkSize - buffer.length, ls.length);

        buffer.addAll(ls.sublist(start, end));

        ls.removeRange(start, end);

        if (buffer.length == chunkSize) {
          yield buffer;
          buffer.clear();
        }
      }
    }
    if (buffer.isNotEmpty) {
      yield buffer;
    }
  }

  @override
  StreamTransformer<RS, RT> cast<RS, RT>() {
    return StreamTransformer<RS, RT>((stream, cancelOnError) {
      return bind(stream as Stream<List<T>>).cast<RT>().listen(null);
    });
  }
}

void main(List<String> args) {
  final list = List.generate(10, (index) => List.generate(index + 1, (i) => i + 1));
  print(list);
  final stream = Stream.fromIterable(list);

  stream.transform(ChunkedStreamTransformer(6)).forEach((e) {
    print("final result: $e");
  });
}
