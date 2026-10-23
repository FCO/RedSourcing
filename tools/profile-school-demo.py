#!/usr/bin/env python3
"""Measure the real school demo without editing its code; emit traces and Mermaid."""
import argparse
import collections
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def invoke(raku, output, profile, index):
    env = dict(os.environ, RAKUDO_RAKUAST='0')
    args = [raku, '-Ilib', '-Iexamples/school/lib']
    if profile:
        args += ['-Itools/lib', '-MSchoolDemoTiming']
        env['SCHOOL_TIMING_OUTPUT'] = str(output / f'trace-{index}.json')
    args += ['examples/school/main.raku', 'demo']
    start_posix = time.time()
    start = time.perf_counter()
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    end_posix = time.time()
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    if result.stderr:
        raise RuntimeError(f'Unexpected demo diagnostics: {result.stderr}')
    if 'Replayed active enrollments: 40' not in result.stdout:
        raise RuntimeError(f'Unexpected demo result: {result.stdout}')
    return dict(wall_ms=elapsed * 1000, start_posix=start_posix,
                end_posix=end_posix, stdout=result.stdout, command=args)


def phases(trace):
    records = trace['records']
    app = [r for r in records if r['parent'] == 0 and r['name'].startswith('App.')]
    def find(name, first=None):
        return [r for r in app if r['name'] == 'App.' + name
                and (first is None or r['arguments'][0] == first)]
    def span(name, rows):
        assert rows, name
        return dict(name=name, start_ms=rows[0]['start_ms'],
                    duration_ms=rows[-1]['start_ms'] + rows[-1]['duration_ms'] - rows[0]['start_ms'],
                    calls=len(rows), record_ids=[r['id'] for r in rows])
    alice = find('enroll', 'alice')
    assert len(alice) == 12 and not alice[10]['success']
    math_reads = find('classroom', 'math')
    math_loop = [r for r in app if find('add-student', 'student-1')[0]['start_ms'] <= r['start_ms']
                 < math_reads[0]['start_ms']]
    overview = [r for r in records if r['parent'] == 0 and r['name'] == 'Entity.load'][-1]
    result = [dict(name='Configuração e schema', start_ms=0,
                   duration_ms=find('add-student', 'alice')[0]['start_ms'], calls=1, record_ids=[]),
              span('Cadastrar Alice', find('add-student', 'alice')),
              span('Criar 11 aulas', [r for r in find('add-class') if r['arguments'][0] != 'math']),
              span('Matricular Alice em 10 aulas', alice[:10]),
              span('Consultar as aulas de Alice', find('student', 'alice')[:1]),
              span('Rejeitar a 11ª matrícula de Alice', alice[10:11]),
              span('Cancelar class-1 e matricular em class-11', [find('cancel', 'alice')[0], alice[11]]),
              span('Consultar Alice novamente', find('student', 'alice')[1:]),
              span('Criar a aula de matemática', find('add-class', 'math')),
              span('Cadastrar 31 alunos e matricular os primeiros 30', math_loop),
              span('Consultar a turma de matemática', math_reads[:1]),
              span('Rejeitar o 31º aluno', find('enroll', 'student-31')[:1]),
              span('Cancelar student-1 e matricular student-31',
                   [find('cancel', 'student-1')[0], find('enroll', 'student-31')[1]]),
              span('Consultar matemática novamente', math_reads[1:]),
              span('Reconstituir SchoolOverview: 40 matrículas ativas', [overview])]
    return result


def participant(name):
    return {'App': 'App', 'Entity': 'Entidade', 'Command': 'Comando',
            'Projection': 'Projection', 'Decision': 'Decisao', 'Journal': 'Journal',
            'Tags': 'Tags', 'Counters': 'Contadores', 'DB': 'Banco', 'SQL': 'Banco',
            'Rules': 'Decisao', 'Event': 'Dados', 'Storage': 'Dados'}[name.split('.')[0]]


def sql_label(sql):
    sql = re.sub(r'\s+', ' ', sql).strip()
    if sql.startswith('WITH changes'):
        return 'CAS em lote: red_sourcing_counter'
    if sql.upper().startswith('SELECT'):
        match = re.search(r'FROM\s+"?(red_sourcing_\w+)', sql, re.I)
        return 'SELECT ' + (match.group(1) if match else 'metadados/schema')
    match = re.search(r'^(INSERT INTO|UPDATE|CREATE TABLE|CREATE INDEX|DELETE FROM)\s+"?([\w]+)', sql, re.I)
    return ' '.join(match.groups()) if match else sql[:80].replace('"', "'")


def detail(trace, record_id):
    records = {r['id']: r for r in trace['records']}
    children = collections.defaultdict(list)
    for r in trace['records']:
        children[r['parent']].append(r)
    lines = ['```mermaid', 'sequenceDiagram', '    autonumber', '    participant Demo']
    for p in ['App', 'Entidade', 'Comando', 'Decisao', 'Projection', 'Tags', 'Journal', 'Contadores', 'Dados', 'Banco']:
        lines.append('    participant ' + p)
    def emit(r, caller):
        target = participant(r['name'])
        name = sql_label(r['sql']) if r['name'] == 'SQL' else r['name']
        label = f"{name} — {r['duration_ms']:.2f} ms"
        if r['name'] == 'SQL':
            label += f", {r['rows']} linhas retornadas"
        lines.append(f'    {caller}->>{target}: {label}')
        for c in children[r['id']]:
            emit(c, target)
        if r['name'] != 'SQL':
            lines.append(f"    {target}-->>{caller}: {'retorna' if r['success'] else 'propaga rejeição'}")
    emit(records[record_id], 'Demo')
    lines.append('```')
    return '\n'.join(lines)


def report(summary, trace):
    p = summary['phases']
    lines = ['# Sequência medida do demo school', '',
             'Execução real de `examples/school/main.raku demo`, SQLite em memória e precompilação aquecida.', '',
             f"Medição local de {summary['measured_at']}. O demo completo cadastra 32 alunos, cria 12 aulas e tenta 44 matrículas. "
             'O benchmark anterior de 3,45 s cobria uma aula, dez cadastros e dez matrículas.', '',
             f"Processo sem instrumentação: **{summary['baseline_median_ms']/1000:.3f} s** (mediana de {summary['runs']} execuções).",
             f"Processo instrumentado: **{summary['profile_median_ms']/1000:.3f} s** (mediana).",
             f"O diagrama usa uma execução real representativa: **{summary['selected_wall_ms']/1000:.3f} s** no processo, "
             f"dos quais **{trace['duration_ms']/1000:.3f} s** dentro do demo.", '',
             'Os tempos das chamadas são inclusivos: filhos já fazem parte do tempo do pai. '
             'Nos blocos SQL, o tempo soma preparação, execução e leitura das linhas no driver; '
             'a hidratação e os handlers ficam no estágio que consome essas linhas. '
             'BEGIN/COMMIT/ROLLBACK aparecem separadamente. Linhas são resultados retornados, não linhas afetadas por UPDATE. '
             'A instrumentação também tem custo.', '',
             '## Demo completo', '', '```mermaid', 'sequenceDiagram', '    autonumber',
             '    participant Processo as Raku / módulos', '    participant Demo as main.raku demo',
             '    participant App as School.App', '    participant Proj as Projections']
    lines.append(f"    Processo->>Demo: Carregamento e medidor prontos — {summary['startup_ms']:.2f} ms")
    for i, phase in enumerate(p):
        target = 'Proj' if i == len(p)-1 else 'App'
        lines.append(f"    Demo->>{target}: {phase['name']} — {phase['duration_ms']:.2f} ms")
        if i == 9:
            lines += ['    Note over Demo,App: Loop: registra um aluno, matricula se número ≤ 30']
        lines.append(f'    {target}-->>Demo: concluído' if i not in [5,11] else f'    {target}-->>Demo: limite atingido, comando Failed')
    lines += [f"    Demo-->>Processo: Impressão/controle entre etapas — {summary['other_demo_ms']:.2f} ms",
              f"    Note over Processo: Serialização do trace e encerramento — {summary['teardown_ms']:.2f} ms", '```', '',
              '| Etapa | Chamadas | Tempo inclusivo (ms) |', '| --- | ---: | ---: |']
    lines += [f"| {x['name']} | {x['calls']} | {x['duration_ms']:.2f} |" for x in p]
    lines += ['', '## Uma matrícula, por dentro', '',
              'Primeira matrícula de Alice em class-1, incluindo a criação inicial do stream de Enrollment. '
              'A consulta OR reconstrói StudentClasses(alice) e ClassRoster(class-1). O bloco valida existência e limites '
              'e emite StudentEnrolled. O comando passa de Pending para Processing e Done. '
              'Cada seta corresponde a uma chamada observada; os SELECTs são identificados pela tabela consultada.', '',
              detail(trace, p[3]['record_ids'][0]), '', '## Rejeição da 11ª aula', '',
              detail(trace, p[5]['record_ids'][0]), '', '## Cancelamento', '',
              detail(trace, p[6]['record_ids'][0]), '', '## Matrícula após o cancelamento', '',
              detail(trace, p[6]['record_ids'][1]), '', '## Rejeição do 31º aluno', '',
              detail(trace, p[11]['record_ids'][0]), '', '## Volume observado', '',
              f"- {summary['sql_count']} execuções de statements; {summary['sql_active_ms']:.2f} ms somados no driver.",
              '- 32 alunos, 12 aulas, 90 comandos: 88 concluídos e duas rejeições de negócio.',
              '- 88 eventos de domínio e 86 snapshots iniciais; 40 matrículas ativas no fim.',
              '- Em snapshots sem decisão ativa, Counters.CAS recebe um lote vazio e retorna sem SQL; nenhum contador é alterado.',
              '- As decisões leem contadores e uma consulta OR para StudentClasses + ClassRoster; '
              'o append valida os contadores com CAS e a unicidade (stream, version).',
              '- O demo habilita a opção flow-tracing na configuração, mas não abre o monitor nem '
              'reconstrói as projections de flow/métricas; apenas grava a causalidade nos registros.', '',
              '## Reprodução', '', '```sh',
              'python3 tools/profile-school-demo.py --runs=3 --output-dir=/tmp/school-demo-profile', '```', '',
              'Os JSONs nesse diretório contêm timestamps, relações pai/filho, SQL e tempos de cada chamada. '
              'O script aquece a execução normal e a instrumentada antes de medir e verifica que ambas produzem a mesma saída.', '',
              'Runtime utilizado:', '', '```text', summary['runtime'].strip(), summary['frontend'], '```', '']
    by_parent = collections.defaultdict(list)
    totals = collections.defaultdict(list)
    for r in trace['records']:
        by_parent[r['parent']].append(r)
        totals[r['name']].append(r['duration_ms'])
    lines += ['## Acumulado por estágio', '',
              'Os acumulados abaixo se sobrepõem. Decision.model inclui construção dos predicados, '
              'reconstrução das duas projections, validação de negócio e emissão quando permitida. '
              'O tempo ativo no driver SQL exclui a hidratação e o trabalho Raku entre as leituras.', '',
              '| Estágio | Chamadas | Tempo inclusivo acumulado (ms) |', '| --- | ---: | ---: |']
    lines += [f"| {name} | {len(values)} | {sum(values):.2f} |"
              for name, values in sorted(totals.items(), key=lambda item: -sum(item[1]))]
    lines += ['', '## Cada chamada do demo', '',
              'As colunas Comando e Decisão já estão incluídas no total da chamada. '
              'O SQL é a soma do tempo ativo no driver dentro dessa operação.', '',
              '| Chamada | Total (ms) | Comando (ms) | Decisão (ms) | SQL (ms) | Statements | Resultado |',
              '| --- | ---: | ---: | ---: | ---: | ---: | --- |']
    def descendants(r):
        result = []
        for c in by_parent[r['id']]:
            result.append(c)
            result.extend(descendants(c))
        return result
    for r in trace['records']:
        if r['parent'] or not (r['name'].startswith('App.') or r['name'] == 'Entity.load'):
            continue
        children = descendants(r)
        command = sum(c['duration_ms'] for c in children if c['name'] == 'Command.run')
        decision = sum(c['duration_ms'] for c in children if c['name'] == 'Decision.model')
        sql = [c for c in children if c['name'] == 'SQL']
        label = r['name'] + '(' + ', '.join(r['arguments']) + ')'
        if r['name'] == 'Entity.load':
            label = 'SchoolOverview.load()'
        lines.append(f"| {label} | {r['duration_ms']:.2f} | {command:.2f} | {decision:.2f} | "
                     f"{sum(c['duration_ms'] for c in sql):.2f} | {len(sql)} | "
                     f"{'ok' if r['success'] else 'rejeitado'} |")
    return '\n'.join(lines) + '\n'


def command_report(summary, trace):
    records = trace['records']
    root = next(r for r in records if r['name'] == 'App.enroll' and r['arguments'] == ['alice', 'class-1'])
    ids = {root['id']}
    rows = [root]
    for r in records:
        if r['parent'] in ids:
            ids.add(r['id'])
            rows.append(r)
    def find(name):
        return [r for r in rows if r['name'] == name]
    def end(r):
        return r['start_ms'] + r['duration_ms']
    def descendants(parent):
        found = {parent['id']}
        result = []
        for r in rows:
            if r['parent'] in found:
                found.add(r['id'])
                result.append(r)
        return result
    command = find('Command.run')[0]
    decision = find('Decision.model')[0]
    drows = descendants(decision)
    savepoint = find('DB.savepoint')[0]
    read = find('Counters.read')[0]
    query = next(r for r in drows if r['name'] == 'SQL' and 'red_sourcing_event' in r['sql'])
    normalize = next(r for r in drows if r['name'] == 'Event.normalize')
    append = next(r for r in drows if r['name'] == 'Journal.append')
    arows = descendants(append)
    historical_apply = [r for r in drows if r['name'] == 'Projection.APPLY' and r['start_ms'] < normalize['start_ms']]
    historical_hydrate = [r for r in drows if r['name'] == 'Storage.hydrate' and r['start_ms'] < normalize['start_ms']]
    historical_inflate = [r for r in drows if r['name'] == 'Event.inflate' and r['parent'] == decision['id'] and r['start_ms'] < normalize['start_ms']]
    last_apply = historical_apply[-1]
    release = find('DB.release-savepoint')[0]
    event_create = next(r for r in arows if r['name'] == 'Storage.create')
    cas = next(r for r in arows if r['name'] == 'Counters.CAS')
    event_insert = next(r for r in arows if r['name'] == 'SQL' and re.search(r'^INSERT INTO\s+"?red_sourcing_event', r['sql'], re.I))
    guard = next(r for r in arows if r['name'] == 'Counters.guards')
    hooks = next(r for r in arows if r['name'] == 'Projection.transactional')
    emitted_inflate = next(r for r in drows if r['name'] == 'Event.inflate' and r['start_ms'] > end(append))
    emitted_apply = next(r for r in drows if r['name'] == 'Projection.APPLY' and r['start_ms'] > end(append))
    done = next(r for r in rows if r['name'] == 'Storage.save' and r['parent'] == command['id'])
    claim = next(r for r in rows if r['name'] == 'SQL' and r['sql'].startswith('UPDATE red_sourcing_command'))
    signatures = sum(r['duration_ms'] for r in drows if r['name'] == 'Rules.signatures')
    filters = sum(r['duration_ms'] for r in drows if r['name'] == 'Rules.event-filter')
    prepare_filters = read['start_ms'] - end(savepoint)
    refresh = find('Command.refresh')
    queue = next(r for r in rows if r['name'] == 'Storage.create' and r['parent'] == root['id'])
    begins, commits = find('DB.begin'), find('DB.commit')
    snapshot = find('Entity.write-snapshot')[0]
    tags = find('Tags.keys')[0]
    sql = find('SQL')
    ms = lambda n: f'{n:.2f} ms'
    diagram = f'''```mermaid
sequenceDiagram
    autonumber
    participant App
    participant C as StoredCommand
    participant A as Enrollment
    participant D as decision-model
    participant P as StudentClasses e ClassRoster
    participant J as Journal
    participant K as Contadores
    participant DB as SQLite

    Note over App,DB: alice em class-1 — total {ms(root['duration_ms'])}
    App->>DB: Buscar snapshot e preparar stream — {ms(begins[0]['start_ms']-root['start_ms'])}
    opt Primeiro uso do stream
        App->>DB: BEGIN — {ms(begins[0]['duration_ms'])}
        App->>A: Criar snapshot inicial — {ms(snapshot['duration_ms'])}
        A->>J: Append do snapshot — {ms(find('Journal.append')[0]['duration_ms'])}
        Note over J,K: Sem decisão ativa, lote vazio de contadores, sem SQL de CAS
        App->>DB: COMMIT — {ms(commits[0]['duration_ms'])}
    end
    App->>C: Persistir Pending — {ms(queue['duration_ms'])}
    Note over C,DB: Inclui BEGIN, INSERT do comando e COMMIT
    App->>C: run — {ms(command['duration_ms'])}
    C->>DB: Atualizar a cópia local do comando — {ms(refresh[0]['duration_ms'])}
    C->>DB: BEGIN de execução — {ms(begins[-1]['duration_ms'])}
    C->>DB: Claim Pending para Processing, SQL — {ms(claim['duration_ms'])}
    Note over C,DB: Estado atualizado pela linha RETURNING do claim; sem SELECT adicional
    C->>A: Carregar agregado — {ms(find('Entity.load')[0]['duration_ms'])}
    Note over A,DB: Snapshot, COERCE e replay do stream
    A-->>C: Agregado restaurado
    C->>A: Preparar e executar enroll — {ms(end(decision)-end(find('Entity.load')[0]))}
    A->>D: decision-model — {ms(decision['duration_ms'])}
    D->>D: Preparar IDs e escopo — {ms(savepoint['start_ms']-decision['start_ms'])}
    D->>DB: SAVEPOINT — {ms(savepoint['duration_ms'])}
    D->>D: Preparar filtros e dependências — {ms(prepare_filters)}
    Note over D: Assinaturas {ms(signatures)}, predicados {ms(filters)}, restante {ms(prepare_filters-signatures-filters)}
    D->>K: Ler versões das dependências — {ms(read['duration_ms'])}
    D->>D: Instanciar views e preparar consulta Red — {ms(query['start_ms']-end(read))}
    rect rgb(245,248,255)
        Note over D,P: Consulta e reconstrução — {ms(end(last_apply)-query['start_ms'])}, incluindo SQL
        D->>DB: SELECT combinado por OR, driver — {ms(query['duration_ms'])}
        D->>D: Hidratar as duas linhas — {ms(sum(r['duration_ms'] for r in historical_hydrate))}
        D->>D: COERCE dos eventos — {ms(sum(r['duration_ms'] for r in historical_inflate))}
        D->>P: APPLY dos eventos anteriores — {ms(sum(r['duration_ms'] for r in historical_apply))}
    end
    D->>A: Registrar decisão, validar limites e preparar evento — {ms(normalize['start_ms']-end(last_apply))}
    rect rgb(240,250,240)
        Note over A,DB: Emissão observada, normalização até hooks — {ms(end(append)-normalize['start_ms'])}
        A->>A: Normalizar payload JSON — {ms(normalize['duration_ms'])}
        A->>K: Gerar chaves das tags — {ms(tags['duration_ms'])}
        A->>J: Append StudentEnrolled — {ms(append['duration_ms'])}
        J->>K: Calcular condições da decisão — {ms(guard['duration_ms'])}
        J->>K: CAS otimista em lote — {ms(cas['duration_ms'])}
        Note over K,DB: Validar versões e incrementar contadores na mesma transação
        J->>DB: Criar StoredEvent pelo Red — {ms(event_create['duration_ms'])}
        Note over J,DB: Inclui INSERT RETURNING, {ms(event_insert['duration_ms'])} ativos no driver
        J->>P: Verificar projections transacionais — {ms(hooks['duration_ms'])}
        Note over P: Nenhuma projection transacional é atualizada neste exemplo
    end
    A->>A: COERCE do novo evento — {ms(emitted_inflate['duration_ms'])}
    A->>A: APPLY StudentEnrolled, active=True — {ms(emitted_apply['duration_ms'])}
    A->>A: Versão, cursor, publicação e retorno do bloco, restante — {ms(release['start_ms']-end(append)-emitted_inflate['duration_ms']-emitted_apply['duration_ms'])}
    Note over A: active=True, versão, cursor e publicação provisória, inclusos nos blocos externos
    A-->>D: True
    D->>DB: RELEASE SAVEPOINT — {ms(release['duration_ms'])}
    D->>D: Finalizar escopo da decisão — {ms(end(decision)-end(release))}
    D-->>A: True
    A-->>C: True
    C->>C: Verificar auto-snapshot e preparar finalização — {ms(done['start_ms']-end(decision))}
    C->>DB: Salvar Done e resultado — {ms(done['duration_ms'])}
    Note over C: Nenhum novo snapshot automático, limite ainda não atingido
    C->>DB: COMMIT de execução — {ms(commits[-1]['duration_ms'])}
    C-->>App: True
```'''
    facts = dict(measured_at=summary['measured_at'], runtime=summary['runtime'], frontend=summary['frontend'],
                 command='School::Enrollment.enroll(student-id=alice, class-id=class-1)',
                 sqlite_database=':memory:', total_ms=root['duration_ms'], command_run_ms=command['duration_ms'],
                 decision_ms=decision['duration_ms'], filters_and_dependencies_ms=prepare_filters,
                 views_and_red_query_preparation_ms=query['start_ms']-end(read),
                 sql_active_ms=sum(r['duration_ms'] for r in sql), sql_count=len(sql), records=rows)
    text = f'''# Comando e emissão de eventos: sequência medida

Amostra: primeira matrícula de Alice em class-1 no demo real da escola. SQLite em memória,
RAKUDO_RAKUAST=0, {summary['measured_at']}. Uma execução instrumentada após aquecimento,
com saída conferida contra a execução sem instrumentação. Não é uma mediana por comando.

Tempos inclusivos: filhos já estão no tempo do pai. Os blocos de preparação são intervalos
entre os pontos observados, incluindo o trabalho Raku desse intervalo. O restante de filtros
inclui análise de dependências, varreduras do AST e outros preparos não cronometrados
separadamente. SQL é tempo ativo de preparar/executar/ler no driver, não o tempo total de
uma consulta Red. Hidratação, COERCE e handlers são mostrados separadamente.

{diagram}

O caminho completo levou **{ms(root['duration_ms'])}**, dos quais **{ms(command['duration_ms'])}**
dentro de `StoredCommand.run` e **{ms(decision['duration_ms'])}** dentro de `decision-model`.
Os **{len(sql)} statements** somaram **{ms(sum(r['duration_ms'] for r in sql))}** ativos no driver.
Tempos Raku e bookkeeping entre chamadas explicam as diferenças entre a soma das etapas e
os blocos externos. Não some os tempos inclusivos entre si.

A emissão inclui o envelope causal (`command-id` e, quando houver, `action-id`) antes do
INSERT. Esse preparo não tem cronômetro próprio e está incluído no append. Depois do INSERT,
o novo evento é aplicado ao agregado. As projections comuns de aluno e turma são
reconstruídas em suas leituras; não são atualizadas automaticamente por essa emissão.

O diagrama mostra o caminho de sucesso síncrono. Rejeições de negócio fazem rollback e
salvam o comando como Failed; conflitos otimistas podem repetir a execução. Esses caminhos
não têm os mesmos tempos. Veja as amostras de rejeição e cancelamento no
[diagrama do demo completo](demo-sequence.md).

Para reproduzir:

```sh
python3 tools/profile-school-demo.py --runs=3 --output-dir=/tmp/school-command-profile
```

O diretório conterá `command-sequence.md`, `command-measurement.json` e os traces completos.
'''
    return text, facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raku', default='raku')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--output-dir', type=Path, default=Path('/tmp/school-demo-profile'))
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be positive')
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    runtime = subprocess.check_output([args.raku, '--version'], text=True)
    print('Warming ordinary and instrumented executions...', flush=True)
    ordinary = invoke(args.raku, output, False, 'warm')
    warm = invoke(args.raku, output, True, 'warm')
    assert ordinary['stdout'] == warm['stdout']
    baselines, profiles = [], []
    for i in range(args.runs):
        baselines.append(invoke(args.raku, output, False, i))
        profiles.append(invoke(args.raku, output, True, i))
        assert baselines[-1]['stdout'] == profiles[-1]['stdout'] == ordinary['stdout']
        print(f"run {i+1}: ordinary={baselines[-1]['wall_ms']/1000:.3f}s profiled={profiles[-1]['wall_ms']/1000:.3f}s", flush=True)
    selected = sorted(range(args.runs), key=lambda i: profiles[i]['wall_ms'])[args.runs//2]
    trace = json.loads((output / f'trace-{selected}.json').read_text())
    steps = phases(trace)
    sql = [r for r in trace['records'] if r['name'] == 'SQL']
    sample = profiles[selected]
    summary = dict(runtime=runtime, measured_at=time.strftime('%Y-%m-%d'),
                   frontend='RAKUDO_RAKUAST=0', driver='SQLite', database=':memory:',
                   runs=args.runs, selected_run=selected,
                   baseline_median_ms=statistics.median(x['wall_ms'] for x in baselines),
                   profile_median_ms=statistics.median(x['wall_ms'] for x in profiles),
                   selected_wall_ms=sample['wall_ms'], phases=steps,
                   startup_ms=(trace['origin_posix'] - sample['start_posix']) * 1000,
                   teardown_ms=(sample['end_posix'] - trace['end_posix']) * 1000,
                   other_demo_ms=trace['duration_ms'] - sum(x['duration_ms'] for x in steps),
                   sql_count=len(sql), sql_active_ms=sum(r['duration_ms'] for r in sql),
                   baselines=baselines, profiles=profiles)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False)+'\n')
    (output / 'sequence.md').write_text(report(summary, trace))
    command_text, command_data = command_report(summary, trace)
    (output / 'command-sequence.md').write_text(command_text)
    (output / 'command-measurement.json').write_text(json.dumps(command_data, indent=2, ensure_ascii=False)+'\n')
    print(f"Report: {output / 'sequence.md'}", flush=True)


if __name__ == '__main__':
    main()
