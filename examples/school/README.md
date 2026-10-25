# School: one enrollment, two consistency rules

Students can participate in at most **10 active classes**, and each class can
have at most **30 active students**. Enrollment checks both limits in one
`decision-model`, using `(ProjectionType) => %ids` pairs and queries inferred from their `APPLY` handlers. Every emit maintains optimistic field/tag counters; no global journal advisory lock is acquired.
One `StudentEnrolled` event updates both projections. Cancellation releases both
the student's allowance and the seat. Duplicate enrollments and cancellations
do not emit additional domain events.

## Run the demonstration

From the repository root:

```sh
raku -Ilib examples/school/main.raku
```

The default demo uses in-memory SQLite. It registers a student and eleven classes,
fills her allowance, then fills a mathematics class with thirty students. It
rejects the two overflow requests, cancels enrollments and uses the freed places.
Finally it reconstructs the global view from persisted events.

```text
Alice classes: 10
Eleventh class rejected: Student already participates in 10 classes
Alice classes after cancellation and enrollment: 10
Math students: 30
Thirty-first student rejected: Class already has 30 students
Math students after cancellation and enrollment: 30
Replayed active enrollments: 40
```

## Operate a persistent school

```sh
cd examples/school
raku -I../../lib main.raku --name=Alice student-add alice
raku -I../../lib main.raku --title=Mathematics class-add math
raku -I../../lib main.raku enroll alice math
raku -I../../lib main.raku student alice
raku -I../../lib main.raku class math
raku -I../../lib main.raku summary
raku -I../../lib main.raku cancel alice math
```

These commands share `school.db`. Each accepts `--database=PATH` and `--file=PATH`;
`REDSOURCING_EXAMPLE_DATABASE` also selects a database. The `demo` subcommand can
use a persistent database explicitly, but needs a fresh store.

Use the same application from Raku:

```raku
use RedSourcing;
use School; # include examples/school/lib at compile time
red-sourcing-defaults(:driver<SQLite>, :database(':memory:'));
my $school = School::App.new.initialize;
$school.add-student: 'alice', 'Alice';
$school.add-class: 'math', 'Mathematics';
$school.enroll: 'alice', 'math';
say $school.student('alice').class-count;   # 1
say $school.classroom('math').student-count; # 1
```

## Domain and decision boundary

| Type | Responsibility |
| --- | --- |
| `Student` | Register a student ID and display name |
| `SchoolClass` | Register a class ID and title |
| `Enrollment` | Commands and active state for one student/class pair |
| `StudentClasses` | Student existence and active classes, filtered by student ID |
| `ClassRoster` | Class existence and active students, filtered by class ID |
| `SchoolOverview` | All registrations and current active enrollments |

The enrollment command loads `StudentClasses` and `ClassRoster` at the same journal
position. The journal checks their combined query before writing. If another
command took the last seat or the student's tenth class, the entire command is
retried and reevaluates the limits. A competing unrelated event does not cause a
retry. No saga or compensating enrollment is needed for these two immediate rules.

The example models active class memberships, not schedules, grades or billing.
Read the [decision-model guide](../../docs/decision-models.md) for API semantics,
predicate restrictions, atomicity and external-effect considerations.

## CLI and web monitor

From this directory, the generic CLI discovers `red-sourcing.rakuconf` and imports
`School` automatically. For example:

```sh
raku -I../../lib ../../bin/red-sourcing.raku list-events --details
raku -I../../lib ../../bin/red-sourcing.raku load School::StudentClasses --id=student-id=alice
raku -I../../lib ../../bin/red-sourcing.raku web-monitor --port=3001
```

Open the existing monitor at `http://127.0.0.1:3001`. Enrollment commands are
available through the `School::Enrollment` aggregate's Operations. This example
has no separate web application.

## Docker and tests

```sh
docker compose up --build
```

The one-shot demo and monitor share `/data/events.db`. Use a fresh volume for a
fresh demonstration. See the [Docker guide](../../docs/docker.md).

The regression tests cover [API and CLI behavior](../../t/56-school-example.rakutest)
and [independent PostgreSQL writers](../../t/55-decision-model-pg.rakutest), including
two students competing for seat thirty and one student competing for a tenth
enrollment in two different classes.

## Sequência e tempos do demo

Veja o [diagrama medido do demo completo](demo-sequence.md), com a sequência geral,
o detalhe de matrícula/rejeição/cancelamento e o tempo de cada chamada. As
[medições em JSON](demo-sequence.json) e `tools/profile-school-demo.py` permitem
reproduzir o relatório.

O [diagrama de um comando e emissão de evento](command-sequence.md) abre os tempos
de filtros, preparação da consulta Red, SQL, hidratação, APPLY, validação otimista
e commit. A [amostra em JSON](command-measurement.json) contém as chamadas observadas.

## SQLite e PostgreSQL

A [comparação medida do demo](driver-comparison.md) executa o mesmo cenário em
SQLite em memória, SQLite em arquivo e PostgreSQL local, com três rodadas
alternadas e bancos vazios. Os [resultados em JSON](driver-comparison.json)
incluem tempos individuais, versões e configurações de durabilidade.

Para reproduzir, com PostgreSQL já iniciado:

```sh
python3 tools/compare-school-drivers.py --pg-host=127.0.0.1 --pg-port=5432 --pg-user=postgres --pg-database=postgres
```

## Reading through proxies

`SchoolOverview.enrollment-count` is declared `is query` and is available
directly on its proxy. The application helpers still return loaded views when
the caller needs several fields from the same reconstructed state.
