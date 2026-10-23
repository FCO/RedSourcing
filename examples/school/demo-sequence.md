# Sequência medida do demo school

Execução real de `examples/school/main.raku demo`, SQLite em memória e precompilação aquecida.

Medição local de 2026-10-20. O demo completo cadastra 32 alunos, cria 12 aulas e tenta 44 matrículas. O benchmark anterior de 3,45 s cobria uma aula, dez cadastros e dez matrículas.

Processo sem instrumentação: **18.110 s** (mediana de 3 execuções).
Processo instrumentado: **18.333 s** (mediana).
O diagrama usa uma execução real representativa: **18.333 s** no processo, dos quais **17.908 s** dentro do demo.

Os tempos das chamadas são inclusivos: filhos já fazem parte do tempo do pai. Nos blocos SQL, o tempo soma preparação, execução e leitura das linhas no driver; a hidratação e os handlers ficam no estágio que consome essas linhas. BEGIN/COMMIT/ROLLBACK aparecem separadamente. Linhas são resultados retornados, não linhas afetadas por UPDATE. A instrumentação também tem custo.

## Demo completo

```mermaid
sequenceDiagram
    autonumber
    participant Processo as Raku / módulos
    participant Demo as main.raku demo
    participant App as School.App
    participant Proj as Projections
    Processo->>Demo: Carregamento e medidor prontos — 314.71 ms
    Demo->>App: Configuração e schema — 903.98 ms
    App-->>Demo: concluído
    Demo->>App: Cadastrar Alice — 260.39 ms
    App-->>Demo: concluído
    Demo->>App: Criar 11 aulas — 635.70 ms
    App-->>Demo: concluído
    Demo->>App: Matricular Alice em 10 aulas — 3092.53 ms
    App-->>Demo: concluído
    Demo->>App: Consultar as aulas de Alice — 65.47 ms
    App-->>Demo: concluído
    Demo->>App: Rejeitar a 11ª matrícula de Alice — 316.70 ms
    App-->>Demo: limite atingido, comando Failed
    Demo->>App: Cancelar class-1 e matricular em class-11 — 361.51 ms
    App-->>Demo: concluído
    Demo->>App: Consultar Alice novamente — 63.03 ms
    App-->>Demo: concluído
    Demo->>App: Criar a aula de matemática — 57.75 ms
    App-->>Demo: concluído
    Demo->>App: Cadastrar 31 alunos e matricular os primeiros 30 — 11158.46 ms
    Note over Demo,App: Loop: registra um aluno, matricula se número ≤ 30
    App-->>Demo: concluído
    Demo->>App: Consultar a turma de matemática — 76.16 ms
    App-->>Demo: concluído
    Demo->>App: Rejeitar o 31º aluno — 329.03 ms
    App-->>Demo: limite atingido, comando Failed
    Demo->>App: Cancelar student-1 e matricular student-31 — 386.07 ms
    App-->>Demo: concluído
    Demo->>App: Consultar matemática novamente — 82.04 ms
    App-->>Demo: concluído
    Demo->>Proj: Reconstituir SchoolOverview: 40 matrículas ativas — 116.64 ms
    Proj-->>Demo: concluído
    Demo-->>Processo: Impressão/controle entre etapas — 2.06 ms
    Note over Processo: Serialização do trace e encerramento — 103.63 ms
```

| Etapa | Chamadas | Tempo inclusivo (ms) |
| --- | ---: | ---: |
| Configuração e schema | 1 | 903.98 |
| Cadastrar Alice | 1 | 260.39 |
| Criar 11 aulas | 11 | 635.70 |
| Matricular Alice em 10 aulas | 10 | 3092.53 |
| Consultar as aulas de Alice | 1 | 65.47 |
| Rejeitar a 11ª matrícula de Alice | 1 | 316.70 |
| Cancelar class-1 e matricular em class-11 | 2 | 361.51 |
| Consultar Alice novamente | 1 | 63.03 |
| Criar a aula de matemática | 1 | 57.75 |
| Cadastrar 31 alunos e matricular os primeiros 30 | 61 | 11158.46 |
| Consultar a turma de matemática | 1 | 76.16 |
| Rejeitar o 31º aluno | 1 | 329.03 |
| Cancelar student-1 e matricular student-31 | 2 | 386.07 |
| Consultar matemática novamente | 1 | 82.04 |
| Reconstituir SchoolOverview: 40 matrículas ativas | 1 | 116.64 |

## Uma matrícula, por dentro

Primeira matrícula de Alice em class-1, incluindo a criação inicial do stream de Enrollment. A consulta OR reconstrói StudentClasses(alice) e ClassRoster(class-1). O bloco valida existência e limites e emite StudentEnrolled. O comando passa de Pending para Processing e Done. Cada seta corresponde a uma chamada observada; os SELECTs são identificados pela tabela consultada.

```mermaid
sequenceDiagram
    autonumber
    participant Demo
    participant App
    participant Entidade
    participant Comando
    participant Decisao
    participant Projection
    participant Tags
    participant Journal
    participant Contadores
    participant Banco
    Demo->>App: App.enroll — 345.09 ms
    App->>Banco: SELECT red_sourcing_event — 0.10 ms, 0 linhas retornadas
    App->>Banco: SELECT red_sourcing_event — 0.12 ms, 0 linhas retornadas
    App->>Banco: DB.begin — 0.15 ms
    Banco->>Banco: BEGIN — 0.06 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Entidade: Entity.write-snapshot — 4.07 ms
    Entidade->>Journal: Journal.append — 3.49 ms
    Journal->>Contadores: Counters.CAS — 0.03 ms
    Contadores-->>Journal: retorna
    Journal->>Banco: INSERT INTO red_sourcing_event — 0.34 ms, 1 linhas retornadas
    Journal-->>Entidade: retorna
    Entidade-->>App: retorna
    App->>Banco: DB.commit — 0.16 ms
    Banco->>Banco: COMMIT — 0.07 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: DB.begin — 0.14 ms
    Banco->>Banco: BEGIN — 0.06 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: INSERT INTO red_sourcing_command — 0.29 ms, 1 linhas retornadas
    App->>Banco: DB.commit — 0.15 ms
    Banco->>Banco: COMMIT — 0.06 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Comando: Command.run — 320.88 ms
    Comando->>Banco: SELECT red_sourcing_command — 0.21 ms, 1 linhas retornadas
    Comando->>Banco: DB.begin — 0.14 ms
    Banco->>Banco: BEGIN — 0.06 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.20 ms, 1 linhas retornadas
    Comando->>Banco: SELECT red_sourcing_command — 0.25 ms, 1 linhas retornadas
    Comando->>Entidade: Entity.load — 15.55 ms
    Entidade->>Entidade: Entity.restore — 11.46 ms
    Entidade->>Banco: SELECT red_sourcing_event — 0.24 ms, 1 linhas retornadas
    Entidade-->>Entidade: retorna
    Entidade->>Banco: SELECT red_sourcing_event — 0.14 ms, 0 linhas retornadas
    Entidade-->>Comando: retorna
    Comando->>Decisao: Decision.model — 292.77 ms
    Decisao->>Banco: DB.savepoint — 0.45 ms
    Banco->>Banco: SAVEPOINT 'red_savepoint_1' — 0.08 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Contadores: Counters.read — 1.26 ms
    Contadores->>Banco: SELECT red_sourcing_counter — 0.40 ms, 2 linhas retornadas
    Contadores-->>Decisao: retorna
    Decisao->>Banco: SELECT red_sourcing_event — 0.65 ms, 2 linhas retornadas
    Decisao->>Tags: Tags.keys — 0.16 ms
    Tags-->>Decisao: retorna
    Decisao->>Journal: Journal.append — 5.15 ms
    Journal->>Contadores: Counters.CAS — 0.74 ms
    Contadores->>Banco: CAS em lote: red_sourcing_counter — 0.42 ms, 2 linhas retornadas
    Contadores-->>Journal: retorna
    Journal->>Banco: INSERT INTO red_sourcing_event — 0.26 ms, 1 linhas retornadas
    Journal-->>Decisao: retorna
    Decisao->>Banco: DB.release-savepoint — 0.47 ms
    Banco->>Banco: RELEASE SAVEPOINT 'red_savepoint_1' — 0.09 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.16 ms, 0 linhas retornadas
    Comando->>Banco: DB.commit — 0.17 ms
    Banco->>Banco: COMMIT — 0.07 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando-->>App: retorna
    App-->>Demo: retorna
```

## Rejeição da 11ª aula

```mermaid
sequenceDiagram
    autonumber
    participant Demo
    participant App
    participant Entidade
    participant Comando
    participant Decisao
    participant Projection
    participant Tags
    participant Journal
    participant Contadores
    participant Banco
    Demo->>App: App.enroll — 316.70 ms
    App->>Banco: SELECT red_sourcing_event — 0.16 ms, 0 linhas retornadas
    App->>Banco: SELECT red_sourcing_event — 0.20 ms, 0 linhas retornadas
    App->>Banco: DB.begin — 0.17 ms
    Banco->>Banco: BEGIN — 0.07 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Entidade: Entity.write-snapshot — 4.68 ms
    Entidade->>Journal: Journal.append — 4.07 ms
    Journal->>Contadores: Counters.CAS — 0.04 ms
    Contadores-->>Journal: retorna
    Journal->>Banco: INSERT INTO red_sourcing_event — 0.34 ms, 1 linhas retornadas
    Journal-->>Entidade: retorna
    Entidade-->>App: retorna
    App->>Banco: DB.commit — 0.17 ms
    Banco->>Banco: COMMIT — 0.07 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: DB.begin — 0.15 ms
    Banco->>Banco: BEGIN — 0.06 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: INSERT INTO red_sourcing_command — 0.27 ms, 1 linhas retornadas
    App->>Banco: DB.commit — 0.16 ms
    Banco->>Banco: COMMIT — 0.06 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Comando: Command.run — 290.80 ms
    Comando->>Banco: SELECT red_sourcing_command — 0.27 ms, 1 linhas retornadas
    Comando->>Banco: DB.begin — 0.15 ms
    Banco->>Banco: BEGIN — 0.06 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.21 ms, 1 linhas retornadas
    Comando->>Banco: SELECT red_sourcing_command — 0.30 ms, 1 linhas retornadas
    Comando->>Entidade: Entity.load — 16.52 ms
    Entidade->>Entidade: Entity.restore — 8.59 ms
    Entidade->>Banco: SELECT red_sourcing_event — 0.28 ms, 1 linhas retornadas
    Entidade-->>Entidade: retorna
    Entidade->>Banco: SELECT red_sourcing_event — 0.18 ms, 0 linhas retornadas
    Entidade-->>Comando: retorna
    Comando->>Decisao: Decision.model — 260.57 ms
    Decisao->>Banco: DB.savepoint — 0.18 ms
    Banco->>Banco: SAVEPOINT 'red_savepoint_11' — 0.07 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Contadores: Counters.read — 0.67 ms
    Contadores->>Banco: SELECT red_sourcing_counter — 0.38 ms, 2 linhas retornadas
    Contadores-->>Decisao: retorna
    Decisao->>Banco: SELECT red_sourcing_event — 1.80 ms, 12 linhas retornadas
    Decisao->>Banco: DB.rollback-to-savepoint — 0.52 ms
    Banco->>Banco: ROLLBACK TO SAVEPOINT 'red_savepoint_11' — 0.10 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Banco: DB.release-savepoint — 0.20 ms
    Banco->>Banco: RELEASE SAVEPOINT 'red_savepoint_11' — 0.08 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Banco: DB.rollback — 0.37 ms
    Banco->>Banco: ROLLBACK — 0.07 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao-->>Comando: propaga rejeição
    Comando->>Banco: UPDATE red_sourcing_command — 0.15 ms, 0 linhas retornadas
    Comando-->>App: propaga rejeição
    App-->>Demo: propaga rejeição
```

## Cancelamento

```mermaid
sequenceDiagram
    autonumber
    participant Demo
    participant App
    participant Entidade
    participant Comando
    participant Decisao
    participant Projection
    participant Tags
    participant Journal
    participant Contadores
    participant Banco
    Demo->>App: App.cancel — 61.73 ms
    App->>Banco: SELECT red_sourcing_event — 0.22 ms, 1 linhas retornadas
    App->>Banco: DB.begin — 0.21 ms
    Banco->>Banco: BEGIN — 0.09 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: INSERT INTO red_sourcing_command — 0.40 ms, 1 linhas retornadas
    App->>Banco: DB.commit — 0.25 ms
    Banco->>Banco: COMMIT — 0.11 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Comando: Command.run — 38.23 ms
    Comando->>Banco: SELECT red_sourcing_command — 0.29 ms, 1 linhas retornadas
    Comando->>Banco: DB.begin — 0.16 ms
    Banco->>Banco: BEGIN — 0.07 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.22 ms, 1 linhas retornadas
    Comando->>Banco: SELECT red_sourcing_command — 0.23 ms, 1 linhas retornadas
    Comando->>Entidade: Entity.load — 14.49 ms
    Entidade->>Entidade: Entity.restore — 8.65 ms
    Entidade->>Banco: SELECT red_sourcing_event — 0.34 ms, 1 linhas retornadas
    Entidade-->>Entidade: retorna
    Entidade->>Banco: SELECT red_sourcing_event — 0.28 ms, 1 linhas retornadas
    Entidade-->>Comando: retorna
    Comando->>Tags: Tags.keys — 0.16 ms
    Tags-->>Comando: retorna
    Comando->>Journal: Journal.append — 9.48 ms
    Journal->>Banco: SELECT metadados/schema — 0.19 ms, 1 linhas retornadas
    Journal->>Contadores: Counters.CAS — 0.64 ms
    Contadores->>Banco: CAS em lote: red_sourcing_counter — 0.36 ms, 2 linhas retornadas
    Contadores-->>Journal: retorna
    Journal->>Banco: INSERT INTO red_sourcing_event — 0.37 ms, 1 linhas retornadas
    Journal-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.16 ms, 0 linhas retornadas
    Comando->>Banco: DB.commit — 0.17 ms
    Banco->>Banco: COMMIT — 0.07 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando-->>App: retorna
    App-->>Demo: retorna
```

## Matrícula após o cancelamento

```mermaid
sequenceDiagram
    autonumber
    participant Demo
    participant App
    participant Entidade
    participant Comando
    participant Decisao
    participant Projection
    participant Tags
    participant Journal
    participant Contadores
    participant Banco
    Demo->>App: App.enroll — 299.72 ms
    App->>Banco: SELECT red_sourcing_event — 0.20 ms, 1 linhas retornadas
    App->>Banco: DB.begin — 0.17 ms
    Banco->>Banco: BEGIN — 0.07 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: INSERT INTO red_sourcing_command — 0.29 ms, 1 linhas retornadas
    App->>Banco: DB.commit — 0.19 ms
    Banco->>Banco: COMMIT — 0.08 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Comando: Command.run — 282.96 ms
    Comando->>Banco: SELECT red_sourcing_command — 0.33 ms, 1 linhas retornadas
    Comando->>Banco: DB.begin — 0.16 ms
    Banco->>Banco: BEGIN — 0.07 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.21 ms, 1 linhas retornadas
    Comando->>Banco: SELECT red_sourcing_command — 0.25 ms, 1 linhas retornadas
    Comando->>Entidade: Entity.load — 12.13 ms
    Entidade->>Entidade: Entity.restore — 8.06 ms
    Entidade->>Banco: SELECT red_sourcing_event — 0.25 ms, 1 linhas retornadas
    Entidade-->>Entidade: retorna
    Entidade->>Banco: SELECT red_sourcing_event — 0.14 ms, 0 linhas retornadas
    Entidade-->>Comando: retorna
    Comando->>Decisao: Decision.model — 258.07 ms
    Decisao->>Banco: DB.savepoint — 0.16 ms
    Banco->>Banco: SAVEPOINT 'red_savepoint_12' — 0.06 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Contadores: Counters.read — 0.79 ms
    Contadores->>Banco: SELECT red_sourcing_counter — 0.42 ms, 2 linhas retornadas
    Contadores-->>Decisao: retorna
    Decisao->>Banco: SELECT red_sourcing_event — 1.79 ms, 13 linhas retornadas
    Decisao->>Tags: Tags.keys — 0.17 ms
    Tags-->>Decisao: retorna
    Decisao->>Journal: Journal.append — 4.55 ms
    Journal->>Contadores: Counters.CAS — 0.71 ms
    Contadores->>Banco: CAS em lote: red_sourcing_counter — 0.40 ms, 2 linhas retornadas
    Contadores-->>Journal: retorna
    Journal->>Banco: INSERT INTO red_sourcing_event — 0.29 ms, 1 linhas retornadas
    Journal-->>Decisao: retorna
    Decisao->>Banco: DB.release-savepoint — 0.21 ms
    Banco->>Banco: RELEASE SAVEPOINT 'red_savepoint_12' — 0.08 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.12 ms, 0 linhas retornadas
    Comando->>Banco: DB.commit — 0.17 ms
    Banco->>Banco: COMMIT — 0.07 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando-->>App: retorna
    App-->>Demo: retorna
```

## Rejeição do 31º aluno

```mermaid
sequenceDiagram
    autonumber
    participant Demo
    participant App
    participant Entidade
    participant Comando
    participant Decisao
    participant Projection
    participant Tags
    participant Journal
    participant Contadores
    participant Banco
    Demo->>App: App.enroll — 329.03 ms
    App->>Banco: SELECT red_sourcing_event — 0.12 ms, 0 linhas retornadas
    App->>Banco: SELECT red_sourcing_event — 0.12 ms, 0 linhas retornadas
    App->>Banco: DB.begin — 0.14 ms
    Banco->>Banco: BEGIN — 0.05 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Entidade: Entity.write-snapshot — 3.72 ms
    Entidade->>Journal: Journal.append — 3.25 ms
    Journal->>Contadores: Counters.CAS — 0.03 ms
    Contadores-->>Journal: retorna
    Journal->>Banco: INSERT INTO red_sourcing_event — 0.27 ms, 1 linhas retornadas
    Journal-->>Entidade: retorna
    Entidade-->>App: retorna
    App->>Banco: DB.commit — 0.15 ms
    Banco->>Banco: COMMIT — 0.06 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: DB.begin — 0.13 ms
    Banco->>Banco: BEGIN — 0.05 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Banco: INSERT INTO red_sourcing_command — 0.25 ms, 1 linhas retornadas
    App->>Banco: DB.commit — 0.14 ms
    Banco->>Banco: COMMIT — 0.05 ms, 0 linhas retornadas
    Banco-->>App: retorna
    App->>Comando: Command.run — 301.28 ms
    Comando->>Banco: SELECT red_sourcing_command — 0.20 ms, 1 linhas retornadas
    Comando->>Banco: DB.begin — 0.14 ms
    Banco->>Banco: BEGIN — 0.05 ms, 0 linhas retornadas
    Banco-->>Comando: retorna
    Comando->>Banco: UPDATE red_sourcing_command — 0.19 ms, 1 linhas retornadas
    Comando->>Banco: SELECT red_sourcing_command — 0.21 ms, 1 linhas retornadas
    Comando->>Entidade: Entity.load — 15.58 ms
    Entidade->>Entidade: Entity.restore — 11.39 ms
    Entidade->>Banco: SELECT red_sourcing_event — 0.23 ms, 1 linhas retornadas
    Entidade-->>Entidade: retorna
    Entidade->>Banco: SELECT red_sourcing_event — 0.14 ms, 0 linhas retornadas
    Entidade-->>Comando: retorna
    Comando->>Decisao: Decision.model — 274.96 ms
    Decisao->>Banco: DB.savepoint — 0.15 ms
    Banco->>Banco: SAVEPOINT 'red_savepoint_43' — 0.06 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Contadores: Counters.read — 0.65 ms
    Contadores->>Banco: SELECT red_sourcing_counter — 0.36 ms, 2 linhas retornadas
    Contadores-->>Decisao: retorna
    Decisao->>Banco: SELECT red_sourcing_event — 3.84 ms, 32 linhas retornadas
    Decisao->>Banco: DB.rollback-to-savepoint — 0.22 ms
    Banco->>Banco: ROLLBACK TO SAVEPOINT 'red_savepoint_43' — 0.08 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Banco: DB.release-savepoint — 0.14 ms
    Banco->>Banco: RELEASE SAVEPOINT 'red_savepoint_43' — 0.05 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao->>Banco: DB.rollback — 0.15 ms
    Banco->>Banco: ROLLBACK — 0.06 ms, 0 linhas retornadas
    Banco-->>Decisao: retorna
    Decisao-->>Comando: propaga rejeição
    Comando->>Banco: UPDATE red_sourcing_command — 0.12 ms, 0 linhas retornadas
    Comando-->>App: propaga rejeição
    App-->>Demo: propaga rejeição
```

## Volume observado

- 1816 statements preparados; 411.72 ms somados no driver.
- 32 alunos, 12 aulas, 90 comandos: 88 concluídos e duas rejeições de negócio.
- 88 eventos de domínio e 86 snapshots iniciais; 40 matrículas ativas no fim.
- Em snapshots sem decisão ativa, Counters.CAS recebe um lote vazio e retorna sem SQL; nenhum contador é alterado.
- As decisões leem contadores e uma consulta OR para StudentClasses + ClassRoster; o append valida os contadores com CAS e a unicidade (stream, version).
- O demo habilita a opção flow-tracing na configuração, mas não abre o monitor nem reconstrói as projections de flow/métricas; apenas grava a causalidade nos registros.

## Reprodução

```sh
python3 tools/profile-school-demo.py --runs=3 --output-dir=/tmp/school-demo-profile
```

Os JSONs nesse diretório contêm timestamps, relações pai/filho, SQL e tempos de cada chamada. O script aquece a execução normal e a instrumentada antes de medir e verifica que ambas produzem a mesma saída.

Runtime utilizado:

```text
Welcome to Rakudo™ v2026.09-198-g50379ea28a.
Implementing the Raku® Programming Language v6.d.
Built on MoarVM version 2026.09-38-g597c5351b.
RAKUDO_RAKUAST=0
```

## Acumulado por estágio

Os acumulados abaixo se sobrepõem. Decision.model inclui construção dos predicados, reconstrução das duas projections, validação de negócio e emissão quando permitida. O tempo ativo no driver SQL exclui a hidratação e o trabalho Raku entre as leituras.

| Estágio | Chamadas | Tempo inclusivo acumulado (ms) |
| --- | ---: | ---: |
| Command.run | 90 | 14217.40 |
| App.enroll | 44 | 13744.61 |
| Decision.model | 44 | 11515.35 |
| App.add-student | 32 | 2041.10 |
| Entity.load | 95 | 1605.05 |
| Entity.restore | 95 | 826.88 |
| Journal.append | 174 | 756.57 |
| App.add-class | 12 | 693.14 |
| SQL | 1816 | 411.72 |
| Entity.write-snapshot | 86 | 370.41 |
| Projection.replay | 5 | 365.35 |
| App.classroom | 2 | 158.20 |
| App.student | 2 | 128.50 |
| App.cancel | 2 | 115.49 |
| Counters.CAS | 174 | 63.36 |
| DB.commit | 264 | 40.98 |
| DB.begin | 266 | 38.49 |
| Counters.read | 44 | 29.37 |
| Tags.keys | 88 | 14.82 |
| DB.release-savepoint | 44 | 7.93 |
| App.initialize | 1 | 7.77 |
| DB.savepoint | 44 | 7.37 |
| DB.rollback-to-savepoint | 2 | 0.74 |
| DB.rollback | 2 | 0.52 |

## Cada chamada do demo

As colunas Comando e Decisão já estão incluídas no total da chamada. O SQL é a soma do tempo ativo no driver dentro dessa operação.

| Chamada | Total (ms) | Comando (ms) | Decisão (ms) | SQL (ms) | Statements | Resultado |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| App.initialize() | 7.77 | 0.00 | 0.00 | 0.00 | 2 | ok |
| App.add-student(alice, Alice) | 260.39 | 175.66 | 0.00 | 5.27 | 19 | ok |
| App.add-class(class-1, Class 1) | 60.43 | 34.29 | 0.00 | 3.43 | 18 | ok |
| App.add-class(class-2, Class 2) | 63.11 | 30.85 | 0.00 | 3.32 | 18 | ok |
| App.add-class(class-3, Class 3) | 55.59 | 28.72 | 0.00 | 3.02 | 18 | ok |
| App.add-class(class-4, Class 4) | 60.55 | 32.30 | 0.00 | 3.16 | 18 | ok |
| App.add-class(class-5, Class 5) | 56.66 | 32.85 | 0.00 | 3.28 | 18 | ok |
| App.add-class(class-6, Class 6) | 56.01 | 32.01 | 0.00 | 3.08 | 18 | ok |
| App.add-class(class-7, Class 7) | 56.50 | 33.31 | 0.00 | 6.09 | 18 | ok |
| App.add-class(class-8, Class 8) | 55.37 | 28.47 | 0.00 | 3.06 | 18 | ok |
| App.add-class(class-9, Class 9) | 56.33 | 29.79 | 0.00 | 3.13 | 18 | ok |
| App.add-class(class-10, Class 10) | 57.81 | 31.39 | 0.00 | 2.95 | 18 | ok |
| App.add-class(class-11, Class 11) | 57.03 | 32.31 | 0.00 | 3.10 | 18 | ok |
| App.enroll(alice, class-1) | 345.09 | 320.88 | 292.77 | 4.34 | 22 | ok |
| App.enroll(alice, class-2) | 302.84 | 278.17 | 250.63 | 4.53 | 22 | ok |
| App.enroll(alice, class-3) | 293.19 | 269.29 | 242.72 | 4.31 | 22 | ok |
| App.enroll(alice, class-4) | 303.59 | 275.07 | 250.58 | 4.77 | 22 | ok |
| App.enroll(alice, class-5) | 304.08 | 278.13 | 250.29 | 4.82 | 22 | ok |
| App.enroll(alice, class-6) | 309.46 | 284.49 | 255.70 | 5.17 | 22 | ok |
| App.enroll(alice, class-7) | 308.13 | 282.45 | 253.31 | 5.27 | 22 | ok |
| App.enroll(alice, class-8) | 309.67 | 280.71 | 256.28 | 5.29 | 22 | ok |
| App.enroll(alice, class-9) | 307.53 | 279.69 | 256.23 | 5.14 | 22 | ok |
| App.enroll(alice, class-10) | 308.64 | 280.69 | 256.86 | 5.28 | 22 | ok |
| App.student(alice) | 65.47 | 0.00 | 0.00 | 1.63 | 2 | ok |
| App.enroll(alice, class-11) | 316.70 | 290.80 | 260.57 | 5.18 | 21 | rejeitado |
| App.cancel(alice, class-1) | 61.73 | 38.23 | 0.00 | 3.39 | 15 | ok |
| App.enroll(alice, class-11) | 299.72 | 282.96 | 258.07 | 5.12 | 18 | ok |
| App.student(alice) | 63.03 | 0.00 | 0.00 | 1.74 | 2 | ok |
| App.add-class(math, Mathematics) | 57.75 | 34.35 | 0.00 | 3.08 | 18 | ok |
| App.add-student(student-1, Student 1) | 55.17 | 29.01 | 0.00 | 2.89 | 18 | ok |
| App.enroll(student-1, math) | 294.13 | 267.56 | 243.07 | 4.06 | 22 | ok |
| App.add-student(student-2, Student 2) | 56.41 | 32.95 | 0.00 | 3.05 | 18 | ok |
| App.enroll(student-2, math) | 298.14 | 270.91 | 246.53 | 4.55 | 22 | ok |
| App.add-student(student-3, Student 3) | 55.31 | 31.68 | 0.00 | 2.92 | 18 | ok |
| App.enroll(student-3, math) | 293.40 | 270.16 | 242.96 | 4.10 | 22 | ok |
| App.add-student(student-4, Student 4) | 58.55 | 32.59 | 0.00 | 2.94 | 18 | ok |
| App.enroll(student-4, math) | 294.87 | 271.42 | 245.01 | 4.17 | 22 | ok |
| App.add-student(student-5, Student 5) | 58.25 | 32.05 | 0.00 | 2.83 | 18 | ok |
| App.enroll(student-5, math) | 306.54 | 281.79 | 252.93 | 4.54 | 22 | ok |
| App.add-student(student-6, Student 6) | 58.23 | 28.94 | 0.00 | 2.96 | 18 | ok |
| App.enroll(student-6, math) | 300.80 | 274.39 | 250.56 | 4.36 | 22 | ok |
| App.add-student(student-7, Student 7) | 54.59 | 28.15 | 0.00 | 6.11 | 18 | ok |
| App.enroll(student-7, math) | 300.62 | 272.40 | 249.12 | 4.46 | 22 | ok |
| App.add-student(student-8, Student 8) | 56.59 | 28.42 | 0.00 | 2.83 | 18 | ok |
| App.enroll(student-8, math) | 300.38 | 274.46 | 251.58 | 4.55 | 22 | ok |
| App.add-student(student-9, Student 9) | 57.19 | 30.33 | 0.00 | 2.93 | 18 | ok |
| App.enroll(student-9, math) | 303.83 | 277.79 | 254.36 | 4.70 | 22 | ok |
| App.add-student(student-10, Student 10) | 55.13 | 27.89 | 0.00 | 2.75 | 18 | ok |
| App.enroll(student-10, math) | 303.32 | 276.63 | 252.48 | 4.81 | 22 | ok |
| App.add-student(student-11, Student 11) | 59.22 | 32.45 | 0.00 | 2.67 | 18 | ok |
| App.enroll(student-11, math) | 301.69 | 279.09 | 252.13 | 4.73 | 22 | ok |
| App.add-student(student-12, Student 12) | 58.17 | 30.79 | 0.00 | 2.66 | 18 | ok |
| App.enroll(student-12, math) | 308.36 | 284.86 | 257.61 | 5.03 | 22 | ok |
| App.add-student(student-13, Student 13) | 55.44 | 31.38 | 0.00 | 2.70 | 18 | ok |
| App.enroll(student-13, math) | 307.05 | 284.54 | 258.41 | 4.92 | 22 | ok |
| App.add-student(student-14, Student 14) | 56.68 | 32.80 | 0.00 | 2.75 | 18 | ok |
| App.enroll(student-14, math) | 307.70 | 280.98 | 258.01 | 6.77 | 22 | ok |
| App.add-student(student-15, Student 15) | 55.35 | 27.60 | 0.00 | 2.67 | 18 | ok |
| App.enroll(student-15, math) | 307.91 | 280.88 | 257.63 | 5.28 | 22 | ok |
| App.add-student(student-16, Student 16) | 60.05 | 31.15 | 0.00 | 2.75 | 18 | ok |
| App.enroll(student-16, math) | 308.52 | 286.37 | 260.59 | 5.16 | 22 | ok |
| App.add-student(student-17, Student 17) | 54.09 | 31.05 | 0.00 | 5.89 | 18 | ok |
| App.enroll(student-17, math) | 310.31 | 287.27 | 260.44 | 5.35 | 22 | ok |
| App.add-student(student-18, Student 18) | 54.87 | 27.52 | 0.00 | 2.57 | 18 | ok |
| App.enroll(student-18, math) | 380.36 | 352.30 | 329.51 | 5.46 | 22 | ok |
| App.add-student(student-19, Student 19) | 60.57 | 32.77 | 0.00 | 2.82 | 18 | ok |
| App.enroll(student-19, math) | 310.20 | 287.98 | 261.69 | 5.59 | 22 | ok |
| App.add-student(student-20, Student 20) | 54.34 | 31.63 | 0.00 | 2.59 | 18 | ok |
| App.enroll(student-20, math) | 313.00 | 286.56 | 263.01 | 5.84 | 22 | ok |
| App.add-student(student-21, Student 21) | 61.14 | 31.47 | 0.00 | 2.65 | 18 | ok |
| App.enroll(student-21, math) | 314.41 | 291.27 | 265.43 | 5.83 | 22 | ok |
| App.add-student(student-22, Student 22) | 56.57 | 28.41 | 0.00 | 2.73 | 18 | ok |
| App.enroll(student-22, math) | 315.58 | 288.70 | 265.85 | 5.93 | 22 | ok |
| App.add-student(student-23, Student 23) | 60.96 | 32.64 | 0.00 | 2.75 | 18 | ok |
| App.enroll(student-23, math) | 316.66 | 294.32 | 267.53 | 6.09 | 22 | ok |
| App.add-student(student-24, Student 24) | 55.57 | 27.31 | 0.00 | 2.67 | 18 | ok |
| App.enroll(student-24, math) | 326.58 | 299.73 | 275.95 | 6.26 | 22 | ok |
| App.add-student(student-25, Student 25) | 59.18 | 34.88 | 0.00 | 3.00 | 18 | ok |
| App.enroll(student-25, math) | 323.02 | 294.96 | 269.85 | 8.47 | 22 | ok |
| App.add-student(student-26, Student 26) | 63.13 | 33.57 | 0.00 | 2.94 | 18 | ok |
| App.enroll(student-26, math) | 321.22 | 298.99 | 270.91 | 6.42 | 22 | ok |
| App.add-student(student-27, Student 27) | 57.66 | 28.50 | 0.00 | 2.80 | 18 | ok |
| App.enroll(student-27, math) | 326.26 | 299.69 | 277.30 | 6.54 | 22 | ok |
| App.add-student(student-28, Student 28) | 56.03 | 28.59 | 0.00 | 2.83 | 18 | ok |
| App.enroll(student-28, math) | 329.37 | 302.42 | 279.49 | 6.63 | 22 | ok |
| App.add-student(student-29, Student 29) | 54.47 | 31.73 | 0.00 | 2.60 | 18 | ok |
| App.enroll(student-29, math) | 324.65 | 296.93 | 273.54 | 6.89 | 22 | ok |
| App.add-student(student-30, Student 30) | 61.39 | 32.41 | 0.00 | 2.77 | 18 | ok |
| App.enroll(student-30, math) | 325.80 | 303.78 | 276.50 | 6.87 | 22 | ok |
| App.add-student(student-31, Student 31) | 60.42 | 31.39 | 0.00 | 2.75 | 18 | ok |
| App.classroom(math) | 76.16 | 0.00 | 0.00 | 3.07 | 2 | ok |
| App.enroll(student-31, math) | 329.03 | 301.28 | 274.96 | 6.56 | 21 | rejeitado |
| App.cancel(student-1, math) | 53.76 | 36.86 | 0.00 | 2.67 | 15 | ok |
| App.enroll(student-31, math) | 332.26 | 310.21 | 286.41 | 6.90 | 18 | ok |
| App.classroom(math) | 82.04 | 0.00 | 0.00 | 3.41 | 2 | ok |
| SchoolOverview.load() | 116.64 | 0.00 | 0.00 | 7.99 | 2 | ok |
