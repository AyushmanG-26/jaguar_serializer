library jaguar_serializer.generator.helpers;

import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:source_gen/source_gen.dart';
import 'package:jaguar_serializer/jaguar_serializer.dart';

import 'package:jaguar_serializer_cli/src/info/info.dart';
import 'package:jaguar_serializer_cli/src/info/info.dart' as $info;
import 'package:jaguar_serializer_cli/src/utils/string.dart';
import 'package:jaguar_serializer_cli/src/utils/type_checkers.dart';
import 'package:jaguar_serializer_cli/src/utils/exceptions.dart';

List<ClassElement> _findSerializerInLib(
    Set<LibraryElement> seen, LibraryElement lib, DartType type) {
  final elements = <ClassElement>[];

  if (seen.contains(lib)) return elements;
  seen.add(lib);

  if (lib.isInSdk) return <ClassElement>[];
  if (lib.isDartCore) return elements;

  try {
    for (Element element in lib.topLevelElements) {
      if (element is ClassElement) {
        if (isSerializer.isAssignableFrom(element)) {
          final InterfaceType ser = element.allSupertypes
              .firstWhere((i) => isSerializer.isExactlyType(i));
          if (TypeChecker.fromStatic(type)
              .isExactlyType(ser.typeArguments[0])) {
            elements.add(element);
            if (elements.length > 1) return elements;
          }
        }
      }
    }
  } catch (e) {}

  try {
    for (LibraryElement ilib in lib.importedLibraries) {
      elements.addAll(_findSerializerInLib(seen, ilib, type));
      if (elements.length > 1) return elements;
    }
  } catch (e) {}

  return elements;
}

/// Instantiates [GenSerializer] from [DartObject]
class AnnotationParser {
  final ConstantReader obj;

  final ClassElement element;

  /// Model type
  DartType? modelType;

  ClassElement? modelClass;

  /// Should fields be included by default
  bool? includeByDefault;

  final Map<String, PropertyAccessorElement> getters =
      <String, PropertyAccessorElement>{};

  final Map<String, PropertyAccessorElement> setters =
      <String, PropertyAccessorElement>{};

  final Map<String, $info.Field> fields = <String, $info.Field>{};
  String? nameFormatter;
  final ctorArguments = <CtorArgument>[];
  final ctorNamedArguments = <ParameterElement>[];

  Map<InterfaceType, ClassElement> providers = {};

  bool? globalNullable;

  AnnotationParser(this.element, this.obj);

  SerializerInfo parse() {
    globalNullable = obj.peek('nullableFields')!.boolValue;
    includeByDefault = obj.peek('includeByDefault')!.boolValue;

    _parseSerializers();
    _parseModelType();
    _parseIgnore();
    _parseFields();

    for ($info.Field f in fields.values) {
      if (f.dontEncode && f.dontDecode) continue;
      if (f.dontEncode && f.dontDecode) continue;
      f.typeInfo = _expandTypeInfo(f.type!, f.processor);
    }
    _makeCtor();
    _parseFieldFormatter(obj.peek('nameFormatter'));
    return SerializerInfo(element.name, modelClass!.displayName, fields,
        ctorArguments: ctorArguments,
        ctorNamedArguments: ctorNamedArguments,
        nameFormatter: nameFormatter);
  }

  /// Parses [modelType] of the Serializer
  void _parseModelType() {
    if (!isSerializer.isAssignableFromType(element.thisType)) {
      throw JCException('Serializers must be extended from `Serializer`!');
    }

    InterfaceType i = element.allSupertypes
        .firstWhere((InterfaceType i) => isSerializer.isExactly(i.element));
    modelType = i.typeArguments.first;
    if (modelType!.isDynamic) throw JCException('Model cannot be dynamic!');
    modelClass = modelType!.element as ClassElement;

    bool isNotStaticOrPrivate(PropertyAccessorElement e) =>
        !e.isStatic && !e.isPrivate;

    final List<PropertyAccessorElement?> accessors =
        <PropertyAccessorElement>[];
    accessors.addAll(modelClass!.accessors.where(isNotStaticOrPrivate));
    for (InterfaceType i in modelClass!.allSupertypes) {
      accessors.addAll(i.accessors.where(isNotStaticOrPrivate));
    }

    for (PropertyAccessorElement? field in accessors) {
      String name = field!.displayName;
      if (name == 'runtimeType') continue;
      if (name == 'hashCode') continue;
      if (fields.containsKey(name)) continue;

      PropertyAccessorElement? other;

      DartType type;
      bool dontEncode = false;
      bool dontDecode = false;
      bool isFinal = false;

      if (field.isGetter) {
        getters[name] = field;
        type = field.returnType;
        other = accessors.firstWhere(
            (p) => p!.displayName == name && p.isSetter,
            orElse: () => null);
        if (other != null)
          setters[name] = other;
        else {
          if (field.isSynthetic) {
            isFinal = true;
          } else {
            dontDecode = true;
          }
        }
      } else {
        setters[name] = field;
        type = field.type.parameters.first.type;

        other = accessors.firstWhere(
            (p) => p!.displayName == name && p.isGetter,
            orElse: () => null);
        if (other != null)
          getters[name] = other;
        else
          dontEncode = true;
      }

      DartObject? annot = (field.metadata as List<ElementAnnotation?>)
          .firstWhere(
              (ElementAnnotation? a) => isProperty
                  .isAssignableFromType(a!.computeConstantValue()!.type!),
              orElse: () => null)!
          .computeConstantValue();
      annot ??= (other?.metadata as List<ElementAnnotation?>)
          .firstWhere(
              (ElementAnnotation? a) => isProperty
                  .isAssignableFromType(a!.computeConstantValue()!.type!),
              orElse: () => null)!
          .computeConstantValue();
      if (annot == null) {
        FieldElement? fe = modelClass!.getField(name);
        if (fe != null) {
          for (ElementAnnotation ea in fe.metadata) {
            ParameterizedType eae =
                ea.computeConstantValue()!.type as ParameterizedType;
            if (isProperty.isAssignableFromType(eae)) {
              annot = ea.computeConstantValue();
              break;
            }
          }
        }
      }

      String encodeTo = name;
      String decodeFrom = name;
      bool nullable = globalNullable!;
      FieldProcessorInfo? processor;
      if (annot != null) {
        dontEncode = annot.getField('dontEncode')!.toBoolValue() ?? false
            ? true
            : dontEncode;
        dontDecode = annot.getField('dontDecode')!.toBoolValue() ?? false
            ? true
            : dontDecode;

        encodeTo = annot.getField('encodeTo')?.toStringValue() ?? encodeTo;
        decodeFrom =
            annot.getField('decodeFrom')?.toStringValue() ?? decodeFrom;

        nullable = annot.getField('isNullable')!.toBoolValue() ?? nullable;
        processor = _parseFieldProcessor(annot.getField('processor'));
      }

      if (includeByDefault! || annot != null) {
        fields[name] = $info.Field(
          name: name,
          dontEncode: dontEncode,
          dontDecode: dontDecode,
          type: type,
          encodeTo: encodeTo,
          decodeFrom: decodeFrom,
          processor: processor,
          isNullable: nullable,
          isFinal: isFinal,
        );
      }
    }
  }

  void _parseIgnore() {
    for (DartObject ig in obj.peek('ignore')!.listValue) {
      String fieldName = _mapToString(ig);
      fields[fieldName] = $info.Field(
          name: fieldName,
          dontEncode: true,
          dontDecode: true,
          type: null,
          encodeTo: null,
          decodeFrom: null,
          processor: null,
          isNullable: null);
    }
  }

  void _parseSerializers() {
    final List<DartObject> list = obj.peek('serializers')?.listValue ?? [];
    list.map((DartObject obj) => obj.toTypeValue()).forEach((DartType? t) {
      if (!isSerializer.isAssignableFromType(t!)) {
        throw JCException('serializers must be sub-type of Serializer!');
      }

      final ClassElement v = t.element as ClassElement;
      final InterfaceType i = v.allSupertypes
          .where((InterfaceType i) => isSerializer.isExactly(i.element))
          .first;

      final DartType key = i.typeArguments[0];
      providers[key as InterfaceType] = v;
    });
  }

  /// Parses fields of the GenSerializer
  void _parseFields() {
    Map<DartObject?, DartObject?> map = obj.peek('fields')!.mapValue;
    for (DartObject? dKey in map.keys)
      _processField(dKey!.toStringValue()!, map[dKey]!);
  }

  void _parseFieldFormatter(ConstantReader? obj) {
    if (obj == null || obj.isNull) return;
    Uri uri = obj.revive().source;
    String? accessor = obj.revive().accessor;
    if (uri.pathSegments.length > 0 ||
        uri.pathSegments.first == 'jaguar_serializer') {
      NameFormatter? nf;
      switch (accessor) {
        case 'toCamelCase':
          nf = toCamelCase as NameFormatter?;
          break;
        case 'toSnakeCase':
          nf = toSnakeCase as NameFormatter?;
          break;
        case 'toKebabCase':
          nf = toKebabCase as NameFormatter?;
          break;
        case 'onlyFirstChar':
          nf = onlyFirstChar as NameFormatter?;
          break;
        case 'onlyFirstCharInCaps':
          nf = onlyFirstCharInCaps as NameFormatter?;
          break;
        case 'onlyFirstCharInLower':
          nf = onlyFirstCharInLower as NameFormatter?;
          break;
        case 'withFirstCharInCaps':
          nf = withFirstCharInCaps as NameFormatter?;
          break;
        case 'withFirstCharInLower':
          nf = withFirstCharInLower as NameFormatter?;
          break;
      }
      if (nf != null) {
        for ($info.Field f in fields.values) {
          if (f.dontDecode && f.dontEncode) continue;
          if (f.encodeTo == f.name) f.encodeTo = nf(f.encodeTo);
          if (f.decodeFrom == f.name) f.decodeFrom = nf(f.decodeFrom);
        }
        return;
      }
    }
    nameFormatter = accessor;
  }

  void _processField(String fieldName, DartObject config) {
    DartType? type = _getTypeOfField(fieldName);
    if (type == null) throw JCException("Field not found $fieldName!");
    FieldProcessorInfo? processor =
        _parseFieldProcessor(config.getField('processor'));
    bool isNullable =
        config.getField('isNullable')?.toBoolValue() ?? globalNullable!;

    fields[fieldName] = $info.Field(
      name: fieldName,
      type: type,
      dontEncode: config.getField('dontEncode')!.toBoolValue()!,
      dontDecode: config.getField('dontDecode')!.toBoolValue()!,
      encodeTo: _getStringField(config, 'encodeTo') ?? fieldName,
      decodeFrom: _getStringField(config, 'decodeFrom') ?? fieldName,
      processor: processor!,
      isNullable: isNullable,
      isFinal: _getFinalityOfField(fieldName),
    );
  }

  void _makeCtor() {
    ConstructorElement? ctor =
        (modelType!.element as ClassElement).unnamedConstructor;
    if (ctor == null)
      throw JCException("Model does not have a default constructor!");

    for (final arg in ctor.parameters) {
      final field = fields[arg.name];
      if (arg.isNotOptional) {
        if (field != null) {
          if (field.isFinal && !field.dontDecode) {
            ctorArguments.add(CtorArgument(arg, true));
          } else {
            ctorArguments.add(CtorArgument(arg, false));
          }
        } else {
          ctorArguments.add(CtorArgument(arg, false));
        }
      } else if (arg.isNamed) {
        if (field != null &&
            !field.dontDecode &&
            (field.isFinal || arg.hasRequired)) {
          ctorNamedArguments.add(arg);
        }
      } else {
        /* TODO
        throw JCException(
            "Optional positional arguments are not supported in constructor!");
            */
      }
    }
  }

  DartType? _getTypeOfField(String name) {
    return (getters[name]?.returnType ?? setters[name]!.parameters.first.type);
  }

  bool _getFinalityOfField(String name) {
    if (getters.containsKey(name)) {
      if (setters.containsKey(name)) return false;
      return getters[name]!.isSynthetic;
    }
    return false;
  }

  TypeInfo _expandTypeInfo(DartType type, FieldProcessorInfo? processor) {
    if (processor != null) {
      DartType deserType = processor.deserialized;
      if (deserType.isDynamic
          // || TypeSystem.isSubtypeOf(deserType, type)
          //TODO:isse check karna hai
          ) {
        return ProcessedTypeInfo(
            "_" + firstCharToLowerCase(processor.instantiationString),
            processor.serializedStr,
            processor.deserializedStr,
            type.getDisplayString(withNullability: false));
      }
    } else {
      if (isDateTime.isExactlyType(type)) {
        return ProcessedTypeInfo(
            'dateTimeUtcProcessor', 'String', 'DateTime', type.displayName);
      }

      if (isDuration.isExactlyType(type)) {
        return ProcessedTypeInfo(
            'durationProcessor', 'int', 'Duration', type.displayName);
      }
    }

    if (type is InterfaceType && isList.isExactlyType(type)) {
      final DartType param = type.typeArguments.first;
      return ListTypeInfo(_expandTypeInfo(param, processor), param.displayName);
    } else if (type is InterfaceType && isMap.isExactlyType(type)) {
      final DartType key = type.typeArguments.first;
      final DartType value = type.typeArguments[1];

      if (key.displayName != "String") {
        throw JCException('Serializer only support "String" key for a Map!');
      }
      return MapTypeInfo(BuiltinTypeInfo('String'), key.displayName,
          _expandTypeInfo(value, processor), value.displayName);
    } else if (type is InterfaceType && isSet.isExactlyType(type)) {
      final DartType param = type.typeArguments.first;
      return SetTypeInfo(_expandTypeInfo(param, processor), param.displayName);
    }

    if (processor != null) {
      throw JCException(
          "FieldProcessor ${processor.instantiationString} processer deserializes ${processor.deserializedStr} to ${processor.serializedStr}. But field has type ${type.getDisplayString(withNullability: false)}.");
    }

    if (isBuiltin(type)) {
      return BuiltinTypeInfo(type.getDisplayString(withNullability: false));
    } else if (type.element is ClassElement &&
        (type.element as ClassElement).isEnum) {
      return EnumTypeInfo(type.element!.displayName);
    } else if (type.isDynamic || type.isDartCoreObject) {
      return ProcessedTypeInfo('passProcessor', 'dynamic', 'dynamic',
          type.getDisplayString(withNullability: false));
    }

    if (providers.containsKey(type)) {
      ClassElement? ser = providers[type];
      return SerializedTypeInfo(
          ser!.displayName, type.getDisplayString(withNullability: false));
    }

    List<ClassElement> ser =
        _findSerializerInLib(Set<LibraryElement>(), element.library, type);
    if (ser.length == 1)
      return SerializedTypeInfo(
          ser.first.displayName, type.getDisplayString(withNullability: false));
    if (ser.length > 1)
      throw JCException(
          'Multiple matching serializers found for ${type.getDisplayString(withNullability: false)} when trying to automatically find serializer!');

    throw JCException(
        'Cannot handle ${type.getDisplayString(withNullability: false)} in ${element.displayName}!');
  }
}

bool _notNull(DartObject? obj) => obj != null && obj.isNull == false;

String? _getStringField(DartObject? v, String name) =>
    v!.getField(name)!.toStringValue()!;

String _mapToString(DartObject? v) => v!.toStringValue()!;

FieldProcessorInfo? _parseFieldProcessor(DartObject? processor) {
  if (!_notNull(processor)) return null;
  return FieldProcessorInfo(processor!.type as ParameterizedType);
}
