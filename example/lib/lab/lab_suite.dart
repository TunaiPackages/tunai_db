import 'lab_case.dart';
import 'scenarios/safety_cases.dart';
import 'scenarios/compatibility_cases.dart';
import 'scenarios/crud_cases.dart';
import 'scenarios/join_cases.dart';
import 'scenarios/lifecycle_cases.dart';
import 'scenarios/query_cases.dart';
import 'scenarios/schema_cases.dart';

List<LabCase> createLabSuite() => [
  ...lifecycleCases(),
  ...crudCases(),
  ...queryCases(),
  ...joinCases(),
  ...schemaCases(),
  ...compatibilityCases(),
  ...safetyCases(),
];
