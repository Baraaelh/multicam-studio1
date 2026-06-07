import 'failures.dart';

sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  T? get valueOrNull => switch (this) {
        Success<T> s => s.value,
        Failure<T> _ => null,
      };

  AppFailure? get failureOrNull => switch (this) {
        Success<T> _ => null,
        Failure<T> f => f.failure,
      };

  R fold<R>({
    required R Function(T value) onSuccess,
    required R Function(AppFailure failure) onFailure,
  }) =>
      switch (this) {
        Success<T> s => onSuccess(s.value),
        Failure<T> f => onFailure(f.failure),
      };
}

final class Success<T> extends Result<T> {
  final T value;
  const Success(this.value);
}

final class Failure<T> extends Result<T> {
  final AppFailure failure;
  const Failure(this.failure);
}
