library jaguar_serializer.json;

import 'dart:convert';

import '../serializer/serializer.dart';
import '../serializer/repo.dart';

/// Repository that serialize/deserialize JSON.
///
/// Same usage as [SerializerRepo]
class JsonRepo extends SerializerRepo {
  JsonRepo(
      {List<Serializer> serializers,
      String typeKey: defaultTypeInfoKey,
      bool withType})
      : super(serializers: serializers, typeKey: typeKey, withType: withType);

  ///@nodoc
  dynamic encode(dynamic object) => JSON.encode(object);

  ///@nodoc
  dynamic decode(dynamic object) => JSON.decode(object as String);

  /// Deserialize a JSON String to an object.
  ///
  /// [object] can be a JSON String, a [List] of JSON String.
  ///
  /// See [SerializerRepo.from] for more information.
  @override
  dynamic deserialize(dynamic object, {Type type, String typeKey}) =>
      super.deserialize(object, type: type, typeKey: typeKey);

  /// Serialize an object to a JSON String
  ///
  /// [object] can be a [List], [Map] or a serializable object.
  ///
  /// See [SerializerRepo.to] for more information.
  @override
  dynamic serialize(dynamic object, {bool withType, String typeKey}) =>
      super.serialize(object, withType: withType, typeKey: typeKey);
}
