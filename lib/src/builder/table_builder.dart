import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/source_gen.dart';

import '../core/case_style.dart';
import '../helpers/utils.dart';
import 'action_builder.dart';
import 'column_builder.dart';
import 'join_table_builder.dart';
import 'query_builder.dart';
import 'stormberry_builder.dart';
import 'view_builder.dart';

class TableBuilder {
  ClassElement element;
  ConstantReader annotation;
  BuilderState state;

  late ConstructorElement constructor;
  late String tableName;
  late ParameterElement? primaryKeyParameter;
  late List<ViewBuilder> views;
  late List<ActionBuilder> actions;
  late List<QueryBuilder> queries;

  TableBuilder(this.element, this.annotation, this.state) {
    // TODO add constructor annotation
    constructor = element.constructors.firstWhere((c) => !c.isPrivate);

    tableName = _getTableName();

    primaryKeyParameter = constructor.parameters
        .whereType<FieldFormalParameterElement>()
        .where((p) => primaryKeyChecker.hasAnnotationOf(p.field!))
        .firstOrNull;

    views = annotation.read('views').listValue.map((o) {
      return ViewBuilder(this, o);
    }).toList();
    actions = annotation.read('actions').listValue.map((o) {
      return ActionBuilder(this, o);
    }).toList();
    queries = annotation.read('queries').listValue.map((o) {
      return QueryBuilder(this, o);
    }).toList();
  }

  String _getTableName({bool singular = false}) {
    var name = element.name;
    if (!singular) {
      if (element.name.endsWith('s')) {
        name += 'es';
      } else if (element.name.endsWith('y')) {
        name = '${name.substring(0, name.length - 1)}ies';
      } else {
        name += 's';
      }
    }
    return state.options.tableCaseStyle.transform(name);
  }

  List<ColumnBuilder> columns = [];

  ColumnBuilder? get primaryKeyColumn => primaryKeyParameter != null
      ? columns.where((c) => c.parameter == primaryKeyParameter).firstOrNull
      : null;

  bool get hasDefaultInsertAction => actions.any((a) =>
      a.className == 'SingleInsertAction' ||
      a.className == 'MultiInsertAction');
  bool get hasDefaultUpdateAction => actions.any((a) =>
      a.className == 'SingleUpdateAction' ||
      a.className == 'MultiUpdateAction');

  bool hasQueryForView(ViewBuilder? view) {
    return queries.any((q) => q.isDefaultForView(view));
  }

  bool get hasDefaultQuery => queries
      .any((q) => q.className == 'SingleQuery' || q.className == 'MultiQuery');

  void prepareColumns() {
    for (var param in constructor.parameters) {
      if (columns.any((c) => c.parameter == param)) {
        continue;
      }

      var isList = param.type.isDartCoreList;
      var dataType =
          isList ? (param.type as InterfaceType).typeArguments[0] : param.type;

      if (!state.builders.containsKey(dataType.element)) {
        columns.add(ColumnBuilder(param, this, state));
      } else {
        var otherBuilder = state.builders[dataType.element]!;

        var selfHasKey = primaryKeyParameter != null;
        var otherHasKey = otherBuilder.primaryKeyParameter != null;

        var otherParam = otherBuilder.findMatchingParam(param);
        var isBothList = param.type.isDartCoreList &&
            (otherParam?.type.isDartCoreList ?? false);

        if (!selfHasKey && !otherHasKey) {
          // Json column
          columns.add(ColumnBuilder(param, this, state));
        } else if (selfHasKey && otherHasKey && isBothList) {
          // Many to Many / One to Many / Many to One

          var joinBuilder = JoinTableBuilder(this, otherBuilder, state);
          if (!state.joinBuilders.containsKey(joinBuilder.tableName)) {
            state.joinBuilders[joinBuilder.tableName] = joinBuilder;
          }

          var selfColumn = ColumnBuilder(param, this, state,
              link: otherBuilder, join: joinBuilder);

          if (otherParam != null) {
            var otherColumn = ColumnBuilder(otherParam, otherBuilder, state,
                link: this, join: joinBuilder);

            otherColumn.referencedColumn = selfColumn;
            selfColumn.referencedColumn = otherColumn;

            otherBuilder.columns.add(otherColumn);
          }

          columns.add(selfColumn);
        } else {
          var selfColumn =
              ColumnBuilder(param, this, state, link: otherBuilder);

          if (otherParam != null) {
            var otherColumn =
                ColumnBuilder(otherParam, otherBuilder, state, link: this);
            selfColumn.referencedColumn = otherColumn;
            otherColumn.referencedColumn = selfColumn;

            otherBuilder.columns.add(otherColumn);
          } else if (selfHasKey) {
            // foreign column
            var otherColumn =
                ColumnBuilder(null, otherBuilder, state, link: this);
            selfColumn.referencedColumn = otherColumn;
            otherColumn.referencedColumn = selfColumn;

            var insertIndex =
                otherBuilder.columns.lastIndexWhere((c) => c.isForeignColumn) +
                    1;
            otherBuilder.columns.insert(insertIndex, otherColumn);
          }

          columns.add(selfColumn);
        }
      }
    }
  }

  ParameterElement? findMatchingParam(ParameterElement param) {
    // TODO add binding
    return constructor.parameters.where((p) {
      var pType = p.type.isDartCoreList
          ? (p.type as InterfaceType).typeArguments[0]
          : p.type;
      return pType.element == param.enclosingElement?.enclosingElement;
    }).firstOrNull;
  }

  String getForeignKeyName({bool plural = false, String? base}) {
    var name = base ?? _getTableName(singular: true);
    if (base != null && plural && name.endsWith('s')) {
      name = name.substring(0, base.length - (base.endsWith('es') ? 2 : 1));
    }
    name = state.options.columnCaseStyle
        .transform('$name-${primaryKeyColumn!.columnName}');
    if (plural) {
      name += name.endsWith('s') ? 'es' : 's';
    }
    return name;
  }

  String generateTableClass() {
    var methods = <String>[];

    for (var query in queries) {
      methods.add(query.buildQueryMethod());
    }

    for (var action in actions) {
      methods.add(action.buildActionMethod());
    }

    return ''
        'class ${element.name}Table {\n'
        '  ${element.name}Table._(this._db);\n'
        '  final Database _db;\n'
        '  static ${element.name}Table? _instance;\n'
        '  static ${element.name}Table _instanceFor(Database db) {\n'
        '    if (_instance == null || _instance!._db != db) {\n'
        '      _instance = ${element.name}Table._(db);\n'
        '    }\n'
        '    return _instance!;\n'
        '  }\n'
        '\n'
        '${methods.join('\n\n').indent()}\n'
        '}';
  }

  String generateViews() {
    var viewClasses = <String>[];

    for (var view in [...views]) {
      viewClasses.add(view.generateClass());
    }

    return viewClasses.join('\n\n');
  }

  String generateActions() {
    var actionClasses = <String>[];

    for (var action in [...actions]) {
      var actionCode = action.generateClasses();
      if (actionCode != null) {
        actionClasses.add(actionCode);
      }
    }

    return actionClasses.join('\n\n');
  }

  String generateQueries() {
    var queryClasses = <String>[];

    for (var query in [...queries]) {
      var queryCode = query.generateClasses();
      if (queryCode != null) {
        queryClasses.add(queryCode);
      }
    }

    return queryClasses.join('\n\n');
  }
}
