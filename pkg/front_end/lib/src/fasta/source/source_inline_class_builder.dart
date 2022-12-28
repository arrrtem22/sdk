// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

import '../../base/common.dart';
import '../builder/builder.dart';
import '../builder/inline_class_builder.dart';
import '../builder/library_builder.dart';
import '../builder/member_builder.dart';
import '../builder/metadata_builder.dart';
import '../builder/name_iterator.dart';
import '../builder/type_builder.dart';
import '../builder/type_variable_builder.dart';
import '../fasta_codes.dart'
    show
        messagePatchDeclarationMismatch,
        messagePatchDeclarationOrigin,
        noLength;
import '../problems.dart';
import '../scope.dart';
import 'class_declaration.dart';
import 'source_builder_mixins.dart';
import 'source_field_builder.dart';
import 'source_library_builder.dart';
import 'source_member_builder.dart';

class SourceInlineClassBuilder extends InlineClassBuilderImpl
    with SourceDeclarationBuilderMixin
    implements ClassDeclaration {
  final InlineClass _inlineClass;

  SourceInlineClassBuilder? _origin;
  SourceInlineClassBuilder? patchForTesting;

  MergedClassMemberScope? _mergedScope;

  @override
  final List<TypeVariableBuilder>? typeParameters;

  final SourceFieldBuilder? representationFieldBuilder;

  SourceInlineClassBuilder(
      List<MetadataBuilder>? metadata,
      int modifiers,
      String name,
      this.typeParameters,
      Scope scope,
      ConstructorScope constructorScope,
      SourceLibraryBuilder parent,
      int startOffset,
      int nameOffset,
      int endOffset,
      InlineClass? referenceFrom,
      this.representationFieldBuilder)
      : _inlineClass = new InlineClass(
            name: name,
            fileUri: parent.fileUri,
            typeParameters:
                TypeVariableBuilder.typeParametersFromBuilders(typeParameters),
            reference: referenceFrom?.reference)
          ..fileOffset = nameOffset,
        super(metadata, modifiers, name, parent, nameOffset, scope,
            constructorScope);

  @override
  SourceLibraryBuilder get libraryBuilder =>
      super.libraryBuilder as SourceLibraryBuilder;

  @override
  SourceInlineClassBuilder get origin => _origin ?? this;

  // TODO(johnniwinther): Add merged scope for inline classes.
  MergedClassMemberScope get mergedScope => _mergedScope ??= isPatch
      ? origin.mergedScope
      : throw new UnimplementedError("SourceInlineClassBuilder.mergedScope");

  @override
  InlineClass get inlineClass => isPatch ? origin._inlineClass : _inlineClass;

  @override
  Annotatable get annotatable => inlineClass;

  /// Builds the [InlineClass] for this inline class builder and inserts the
  /// members into the [Library] of [libraryBuilder].
  ///
  /// [addMembersToLibrary] is `true` if the inline class members should be
  /// added to the library. This is `false` if the inline class is in conflict
  /// with another library member. In this case, the inline class member should
  /// not be added to the library to avoid name clashes with other members in
  /// the library.
  InlineClass build(LibraryBuilder coreLibrary,
      {required bool addMembersToLibrary}) {
    DartType representationType;
    if (representationFieldBuilder != null) {
      TypeBuilder typeBuilder = representationFieldBuilder!.type;
      if (typeBuilder.isExplicit) {
        representationType =
            typeBuilder.build(libraryBuilder, TypeUse.fieldType);
      } else {
        representationType = const DynamicType();
      }
    } else {
      representationType = const InvalidType();
    }
    _inlineClass.declaredRepresentationType = representationType;

    buildInternal(coreLibrary, addMembersToLibrary: addMembersToLibrary);

    return _inlineClass;
  }

  @override
  void addMemberDescriptorInternal(SourceMemberBuilder memberBuilder,
      Member member, BuiltMemberKind memberKind, Reference memberReference) {
    String name = memberBuilder.name;
    InlineClassMemberKind kind;
    switch (memberKind) {
      case BuiltMemberKind.Constructor:
      case BuiltMemberKind.RedirectingFactory:
      case BuiltMemberKind.Field:
      case BuiltMemberKind.Method:
      case BuiltMemberKind.ExtensionMethod:
      case BuiltMemberKind.ExtensionGetter:
      case BuiltMemberKind.ExtensionSetter:
      case BuiltMemberKind.ExtensionOperator:
      case BuiltMemberKind.ExtensionTearOff:
        unhandled("${member.runtimeType}:${memberKind}", "buildMembers",
            memberBuilder.charOffset, memberBuilder.fileUri);
      case BuiltMemberKind.ExtensionField:
      case BuiltMemberKind.LateIsSetField:
        kind = InlineClassMemberKind.Field;
        break;
      case BuiltMemberKind.InlineClassConstructor:
        kind = InlineClassMemberKind.Constructor;
        break;
      case BuiltMemberKind.InlineClassMethod:
        kind = InlineClassMemberKind.Method;
        break;
      case BuiltMemberKind.InlineClassGetter:
      case BuiltMemberKind.LateGetter:
        kind = InlineClassMemberKind.Getter;
        break;
      case BuiltMemberKind.InlineClassSetter:
      case BuiltMemberKind.LateSetter:
        kind = InlineClassMemberKind.Setter;
        break;
      case BuiltMemberKind.InlineClassOperator:
        kind = InlineClassMemberKind.Operator;
        break;
      case BuiltMemberKind.InlineClassTearOff:
        kind = InlineClassMemberKind.TearOff;
        break;
      case BuiltMemberKind.InlineClassFactory:
        kind = InlineClassMemberKind.Factory;
        break;
    }
    // ignore: unnecessary_null_comparison
    assert(kind != null);
    inlineClass.members.add(new InlineClassMemberDescriptor(
        name: new Name(name, libraryBuilder.library),
        member: memberReference,
        isStatic: memberBuilder.isStatic,
        kind: kind));
  }

  @override
  void applyPatch(Builder patch) {
    if (patch is SourceInlineClassBuilder) {
      patch._origin = this;
      if (retainDataForTesting) {
        patchForTesting = patch;
      }
      scope.forEachLocalMember((String name, Builder member) {
        Builder? memberPatch =
            patch.scope.lookupLocalMember(name, setter: false);
        if (memberPatch != null) {
          member.applyPatch(memberPatch);
        }
      });
      scope.forEachLocalSetter((String name, Builder member) {
        Builder? memberPatch =
            patch.scope.lookupLocalMember(name, setter: true);
        if (memberPatch != null) {
          member.applyPatch(memberPatch);
        }
      });

      // TODO(johnniwinther): Check that type parameters and on-type match
      // with origin declaration.
    } else {
      libraryBuilder.addProblem(messagePatchDeclarationMismatch,
          patch.charOffset, noLength, patch.fileUri, context: [
        messagePatchDeclarationOrigin.withLocation(
            fileUri, charOffset, noLength)
      ]);
    }
  }

  // TODO(johnniwinther): Implement representationType.
  @override
  DartType get declaredRepresentationType => throw new UnimplementedError();

  @override
  Iterator<T> fullConstructorIterator<T extends MemberBuilder>() {
    // TODO(johnniwinther): Implement fullConstructorIterator
    throw new UnimplementedError();
  }

  @override
  NameIterator<T> fullConstructorNameIterator<T extends MemberBuilder>() {
    // TODO(johnniwinther): Implement fullConstructorNameIterator
    throw new UnimplementedError();
  }

  @override
  Iterator<T> fullMemberIterator<T extends Builder>() {
    // TODO(johnniwinther): Implement fullMemberIterator
    throw new UnimplementedError();
  }

  @override
  NameIterator<T> fullMemberNameIterator<T extends Builder>() {
    // TODO(johnniwinther): Implement fullMemberNameIterator
    throw new UnimplementedError();
  }

  @override
  bool get isMixinDeclaration => false;

  @override
  bool get hasGenerativeConstructor {
    // TODO(johnniwinther): Implement hasGenerativeConstructor
    throw new UnimplementedError();
  }
}
