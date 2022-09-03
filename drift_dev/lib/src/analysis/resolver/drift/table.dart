import 'package:collection/collection.dart';
import 'package:recase/recase.dart';
import 'package:sqlparser/sqlparser.dart';

import '../../driver/error.dart';
import '../../results/column.dart';
import '../../results/element.dart';
import '../../results/table.dart';
import '../intermediate_state.dart';
import '../resolver.dart';
import 'type_mapper.dart';

class DriftTableResolver extends LocalElementResolver<DiscoveredDriftTable> {
  DriftTableResolver(super.discovered, super.resolver, super.state);

  @override
  Future<DriftTable> resolve() async {
    Table table;
    final references = <DriftElement>{};

    try {
      final reader = SchemaFromCreateTable(
        driftExtensions: true,
        driftUseTextForDateTime:
            resolver.driver.options.storeDateTimeValuesAsText,
      );
      table = reader.read(discovered.createTable);
    } catch (e, s) {
      resolver.driver.backend.log
          .warning('Error reading table from internal statement', e, s);
      reportError(DriftAnalysisError.inDriftFile(
        discovered.createTable.tableNameToken ?? discovered.createTable,
        'The structure of this table could not be extracted, possibly due to a '
        'bug in drift_dev.',
      ));
      rethrow;
    }

    final columns = <DriftColumn>[];

    for (final column in table.resultColumns) {
      String? overriddenDartName;
      final type = column.type.sqlTypeToDrift(resolver.driver.options);
      final constraints = <DriftColumnConstraint>[];

      for (final constraint in column.constraints) {
        if (constraint is DriftDartName) {
          overriddenDartName = constraint.dartName;
        } else if (constraint is ForeignKeyColumnConstraint) {
          // Note: Warnings about whether the referenced column exists or not
          // are reported later, we just need to know dependencies before the
          // lint step of the analysis.
          final referenced =
              await resolver.resolveReferenceOrReportError<DriftTable>(
            this,
            constraint.clause.foreignTable.tableName,
            (msg) => DriftAnalysisError.inDriftFile(
              constraint.clause.foreignTable.tableNameToken ?? constraint,
              msg,
            ),
          );

          if (referenced != null) {
            references.add(referenced);

            // Try to resolve this column to track the exact dependency. Don't
            // report a warning if this fails, a separate lint step does that.
            final columnName =
                constraint.clause.columnNames.firstOrNull?.columnName;
            if (columnName != null) {
              final targetColumn = referenced.columns
                  .firstWhereOrNull((c) => c.hasEqualSqlName(columnName));

              if (targetColumn != null) {
                constraints.add(ForeignKeyReference(
                  targetColumn,
                  constraint.clause.onUpdate,
                  constraint.clause.onDelete,
                ));
              }
            }
          }
        }
      }

      columns.add(DriftColumn(
        sqlType: type,
        nullable: column.type.nullable != false,
        nameInSql: column.name,
        nameInDart: overriddenDartName ?? ReCase(column.name).camelCase,
        constraints: constraints,
        declaration: DriftDeclaration(
          state.ownId.libraryUri,
          column.definition!.nameToken!.span.start.offset,
        ),
      ));
    }

    return DriftTable(
      discovered.ownId,
      DriftDeclaration(
        state.ownId.libraryUri,
        discovered.createTable.firstPosition,
      ),
      columns: columns,
      references: references.toList(),
    );
  }
}