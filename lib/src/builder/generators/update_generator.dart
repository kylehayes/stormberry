import '../column/column_builder.dart';
import '../column/field_column_builder.dart';
import '../column/foreign_column_builder.dart';
import '../column/reference_column_builder.dart';
import '../table_builder.dart';

class UpdateGenerator {
  String generateUpdateMethod(TableBuilder table) {
    var deepUpdates = <String>[];

    for (var column
        in table.columns.whereType<ReferenceColumnBuilder>().where((c) => c.linkBuilder.primaryKeyColumn == null)) {
      if (column.linkBuilder.columns
          .where((c) => c is ForeignColumnBuilder && c.linkBuilder != table && !c.isNullable)
          .isNotEmpty) {
        continue;
      }

      if (!column.isList) {
        var requestParams = <String>[];
        for (var c in column.linkBuilder.columns.whereType<ParameterColumnBuilder>()) {
          if (c is ForeignColumnBuilder) {
            if (c.linkBuilder == table) {
              requestParams.add('${c.paramName}: r.${table.primaryKeyColumn!.paramName}');
            }
          } else {
            requestParams.add('${c.paramName}: r.${column.paramName}!.${c.paramName}');
          }
        }

        var deepUpdate = '''
          await _${column.linkBuilder.element.name}Repository(db).update(db, requests.where((r) => r.${column.paramName} != null).map((r) {
            return ${column.linkBuilder.element.name}UpdateRequest(${requestParams.join(', ')});
          }).toList());
        ''';

        deepUpdates.add(deepUpdate);
      } else {
        var requestParams = <String>[];
        for (var c in column.linkBuilder.columns.whereType<ParameterColumnBuilder>()) {
          if (c is ForeignColumnBuilder) {
            if (c.linkBuilder == table) {
              requestParams.add('${c.paramName}: r.${table.primaryKeyColumn!.paramName}');
            }
          } else {
            requestParams.add('${c.paramName}: rr.${c.paramName}');
          }
        }

        var deepUpdate = '''
          await _${column.linkBuilder.element.name}Repository(db).update(db, requests.where((r) => r.${column.paramName} != null).expand((r) {
            return r.${column.paramName}!.map((rr) => ${column.linkBuilder.element.name}UpdateRequest(${requestParams.join(', ')}));
          }).toList());
        ''';

        deepUpdates.add(deepUpdate);
      }
    }

    var hasPrimaryKey = table.primaryKeyColumn != null;
    var setColumns = table.columns.whereType<NamedColumnBuilder>().where((c) =>
        (hasPrimaryKey ? c != table.primaryKeyColumn : c is FieldColumnBuilder) &&
        (c is! FieldColumnBuilder || !c.isAutoIncrement));
    var updateColumns = table.columns
        .whereType<NamedColumnBuilder>()
        .where((c) => table.primaryKeyColumn == c || c is! FieldColumnBuilder || !c.isAutoIncrement);

    return '''
        @override
        Future<void> update(Database db, List<${table.element.name}UpdateRequest> requests) async {
          if (requests.isEmpty) return;
          await db.query(
            'UPDATE "${table.tableName}"\\n'
            'SET ${setColumns.map((c) => '"${c.columnName}" = COALESCE(UPDATED."${c.columnName}"::${c.sqlType}, "${table.tableName}"."${c.columnName}")').join(', ')}\\n'
            'FROM ( VALUES \${requests.map((r) => '( ${updateColumns.map((c) => '\${registry.encode(r.${c.paramName})}').join(', ')} )').join(', ')} )\\n'
            'AS UPDATED(${updateColumns.map((c) => '"${c.columnName}"').join(', ')})\\n'
            'WHERE ${hasPrimaryKey ? '"${table.tableName}"."${table.primaryKeyColumn!.columnName}" = UPDATED."${table.primaryKeyColumn!.columnName}"' : table.columns.whereType<ForeignColumnBuilder>().map((c) => '"${table.tableName}"."${c.columnName}" = UPDATED."${c.columnName}"').join(' AND ')}',
          );
          ${deepUpdates.isNotEmpty ? deepUpdates.join() : ''}
        }
      ''';
  }

  String generateUpdateRequest(TableBuilder table) {
    var requestClassName = '${table.element.name}UpdateRequest';
    var requestFields = <MapEntry<String, String>>[];

    for (var column in table.columns) {
      if (column is FieldColumnBuilder) {
        if (column == table.primaryKeyColumn || !column.isAutoIncrement) {
          requestFields.add(MapEntry(
            column.parameter.type.getDisplayString(withNullability: false) +
                (column == table.primaryKeyColumn ? '' : '?'),
            column.paramName,
          ));
        }
      } else if (column is ReferenceColumnBuilder && column.linkBuilder.primaryKeyColumn == null) {
        if (column.linkBuilder.columns
            .where((c) => c is ForeignColumnBuilder && c.linkBuilder != table && !c.isNullable)
            .isNotEmpty) {
          continue;
        }
        requestFields.add(MapEntry(
            column.parameter!.type.getDisplayString(withNullability: false) +
                (column == table.primaryKeyColumn ? '' : '?'),
            column.paramName));
      } else if (column is ForeignColumnBuilder) {
        var fieldNullSuffix = column == table.primaryKeyColumn ? '' : '?';
        String fieldType;
        if (column.linkBuilder.primaryKeyColumn == null) {
          fieldType = column.linkBuilder.element.name;
          if (column.isList) {
            fieldType = 'List<$fieldType>';
          }
        } else {
          fieldType = column.linkBuilder.primaryKeyColumn!.dartType;
        }
        requestFields.add(MapEntry('$fieldType$fieldNullSuffix', column.paramName));
      }
    }

    return '''
      ${table.updateRequestAnnotation ?? ''}
      class $requestClassName {
        $requestClassName({${requestFields.map((f) => '${f.key.endsWith('?') ? '' : 'required '}this.${f.value}').join(', ')}});
        ${requestFields.map((f) => '${f.key} ${f.value};').join('\n')}
      }
    ''';
  }
}
