#!/usr/bin/env python3
"""Compare the unchanged school demo on SQLite memory/file and PostgreSQL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
CASES = ('sqlite-memory', 'sqlite-file', 'postgresql')
EXPECTED = '''Alice classes: 10
Eleventh class rejected: Student already participates in 10 classes
Alice classes after cancellation and enrollment: 10
Math students: 30
Thirty-first student rejected: Class already has 30 students
Math students after cancellation and enrollment: 30
Replayed active enrollments: 40
'''
PROBE = r'''
use Red;
use Red::DB;
use RedSourcing::Config;
use RedSourcing::Storage;
use JSON::Fast;
my $settings = red-sourcing-defaults(:file(@*ARGS[0]), :database(@*ARGS[1]), :!initialize);
my $db = get-RED-DB;
sub scalar-query(Str $sql) { storage-query($db, $sql).head.values.head.Str }
my %metadata = driver => $settings.driver, red_version => Red.^ver.Str,
    flow_tracing => $settings.flow-tracing, auto_snapshot => $settings.auto-snapshot;
if $settings.driver eq 'SQLite' {
    %metadata<server_version> = scalar-query('SELECT sqlite_version()');
    %metadata{$_} = scalar-query("PRAGMA $_") for <journal_mode synchronous>;
} else {
    %metadata{$_} = scalar-query("SHOW $_") for <server_version fsync synchronous_commit full_page_writes>;
}
say to-json(%metadata, :!pretty);
'''


def checked(args, env, timeout=300):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {result.stderr or result.stdout}")
    if result.stderr:
        raise RuntimeError(f"Unexpected diagnostics: {result.stderr}")
    return result.stdout


def raku_string(value):
    return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'") + "'"


def configuration(driver, database, connection):
    source = (ROOT / 'examples/school/red-sourcing.rakuconf').read_text()
    substitutions = {
        r"\.driver\s*=\s*'SQLite'": '.driver = ' + raku_string(driver),
        r"\.database\s*=\s*'school\.db'": '.database = ' + raku_string(database),
        r'\.includes\s*=\s*<lib>': '.includes = [' + raku_string(ROOT / 'examples/school/lib') + ']',
    }
    for pattern, replacement in substitutions.items():
        source, count = re.subn(pattern, lambda match: replacement, source)
        if count != 1:
            raise RuntimeError(f'The demo config changed; cannot replace {pattern}')
    if connection:
        pairs = ', '.join(f'{key} => {value if isinstance(value, int) else raku_string(value)}'
                          for key, value in connection.items())
        position = source.rindex('}')
        source = source[:position] + '    .connection = %(' + pairs + ');\n' + source[position:]
    return source


def psql(args, env, sql):
    # Identifiers in sql are generated UUIDs, never user-provided table names.
    return checked(['psql', '--no-psqlrc', '--quiet', '--tuples-only', '--no-align',
                    '--set=ON_ERROR_STOP=1', '-h', args.pg_host, '-p', str(args.pg_port),
                    '-U', args.pg_user, '-d', args.pg_database, '-c', sql], env, timeout=30).strip()


def run_case(args, env, case, warmup, iteration, directory):
    schema = 'rs_school_compare_' + uuid.uuid4().hex
    database = ':memory:' if case == 'sqlite-memory' else str(directory / f'{schema}.sqlite')
    connection = {}
    if case == 'postgresql':
        database = args.pg_database
        connection = dict(host=args.pg_host, port=args.pg_port, user=args.pg_user,
                          options=f'-csearch_path={schema} -cclient_min_messages=warning')
    config = directory / f'{schema}.rakuconf'
    config.write_text(configuration('Pg' if case == 'postgresql' else 'SQLite', database, connection))
    try:
        if case == 'postgresql':
            psql(args, env, f'CREATE SCHEMA "{schema}"')
        command = [args.raku, '-Ilib', '-Iexamples/school/lib', 'examples/school/main.raku',
                   '--file=' + str(config), '--database=' + database, 'demo']
        start = time.perf_counter()
        output = checked(command, env)
        seconds = time.perf_counter() - start
        if output != EXPECTED:
            raise RuntimeError(f'{case}: demo output differs from expected result: {output!r}')
        # Outside the timed process. Same Red driver/config, so connection-local
        # PRAGMAs are observed rather than guessed from a Python SQLite handle.
        metadata = json.loads(checked([args.raku, '-Ilib', '-e', PROBE, str(config), database], env))
        return dict(case=case, warmup=warmup, iteration=iteration, seconds=seconds,
                    stdout=output, settings=metadata, database_empty_at_start=True)
    finally:
        if case == 'postgresql':
            psql(args, env, f'SET client_min_messages TO warning; DROP SCHEMA IF EXISTS "{schema}" CASCADE')


def summarize(runs):
    result = {}
    for case in CASES:
        times = [r['seconds'] for r in runs if r['case'] == case and not r['warmup']]
        result[case] = dict(seconds=times, median_seconds=statistics.median(times),
                            min_seconds=min(times), max_seconds=max(times))
    pg = result['postgresql']['median_seconds']
    for case in CASES[:2]:
        sqlite = result[case]['median_seconds']
        result[case]['postgresql_time_ratio'] = pg / sqlite
        result[case]['postgresql_time_difference_percent'] = (pg / sqlite - 1) * 100
    return result


def markdown(data):
    if data['status'] != 'complete':
        return '# Comparação incompleta\n\n' + data.get('error', 'A medição não terminou.') + '\n'
    summary = data['summary']
    lines = ['# Demo school: SQLite e PostgreSQL', '',
             f"Medição local de {data['measured_at']}, demo completo sem instrumentação.", '',
             'Um aquecimento por cenário, seguido de três rodadas em ordem alternada. '
             'Cada execução começa vazia. O tempo é do processo completo: carregamento dos módulos, '
             'conexão, tabelas/índices e operações do demo. Preparação do schema PostgreSQL e '
             'inicialização do servidor ficam fora do cronômetro.', '',
             '| Cenário | Execuções (s) | Mediana (s) | Mínimo–máximo (s) |',
             '| --- | --- | ---: | --- |']
    for case in CASES:
        item = summary[case]
        values = ', '.join(f'{x:.3f}' for x in item['seconds'])
        lines.append(f"| {case} | {values} | {item['median_seconds']:.3f} | "
                     f"{item['min_seconds']:.3f}–{item['max_seconds']:.3f} |")
    lines += ['', 'Comparação de tempos do PostgreSQL:', '']
    for case in CASES[:2]:
        item = summary[case]
        percent = item['postgresql_time_difference_percent']
        direction = 'maior' if percent >= 0 else 'menor'
        lines.append(f"- Em relação a {case}: tempo **{abs(percent):.1f}% {direction}**, "
                     f"razão **{item['postgresql_time_ratio']:.3f}×**.")
    lines += ['', 'SQLite em arquivo versus PostgreSQL compara os dois caminhos persistentes. '
              'SQLite em memória representa o demo padrão. PostgreSQL usa TCP local; SQLite está '
              'embutido no processo. Os resultados incluem essas diferenças. Não houve alteração '
              'de configuração para desabilitar durabilidade.', '',
              'Todas as saídas foram idênticas: Alice termina com dez aulas, matemática com trinta '
              'alunos, duas rejeições esperadas e quarenta matrículas ativas no replay final.', '',
              '## Configuração observada', '',
              '| Cenário | Versão do banco | Configurações efetivas |', '| --- | --- | --- |']
    for case in CASES:
        settings = next(r['settings'] for r in data['runs'] if r['case'] == case)
        keys = ('journal_mode', 'synchronous') if case != 'postgresql' else ('fsync', 'synchronous_commit', 'full_page_writes')
        flags = ', '.join(f'{k}={settings[k]}' for k in keys)
        lines.append(f"| {case} | {settings['server_version']} | {flags} |")
    lines += ['', '`synchronous=2` corresponde a FULL no SQLite; em memória não há arquivo durável. '
              'As configurações foram consultadas fora do cronômetro usando o mesmo driver Red. '
              'O tracing mantém o valor da configuração original, sem reconstruir flow ou métricas.', '',
              f"Red: **{data['red_version']}**. Plataforma: {data['platform']}. Frontend: `RAKUDO_RAKUAST=0`.",
              '', '```text', data['runtime'].strip(), '```', '',
              '## Reprodução', '', 'Com um PostgreSQL local já iniciado:', '', '```sh',
              'python3 tools/compare-school-drivers.py --pg-host=127.0.0.1 --pg-port=5432 \\',
              '  --pg-user=postgres --pg-database=postgres --output-dir=/tmp/school-driver-comparison',
              '```', '', 'O script aceita `--raku` para selecionar o executável. Bibliotecas nativas e '
              'autenticação seguem o ambiente local. Ele cria/remove somente seus próprios schemas '
              'e arquivos temporários, sem iniciar ou parar o servidor. O JSON gerado contém os '
              'tempos individuais, configurações e a impressão digital dos fontes medidos.', '']
    return '\n'.join(lines)


def source_fingerprint():
    fingerprint = hashlib.sha256()
    sources = sorted((ROOT / 'lib').rglob('*.rakumod')) + [ROOT / p for p in (
        'examples/school/main.raku', 'examples/school/lib/School.rakumod', 'examples/school/red-sourcing.rakuconf')]
    for source in sources:
        fingerprint.update(str(source.relative_to(ROOT)).encode() + b'\0' + source.read_bytes())
    return fingerprint.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raku', default='raku')
    parser.add_argument('--pg-host', default=os.environ.get('PGHOST', '127.0.0.1'))
    parser.add_argument('--pg-port', type=int, default=int(os.environ.get('PGPORT', '5432')))
    parser.add_argument('--pg-user', default=os.environ.get('PGUSER') or os.environ.get('USER', 'postgres'))
    parser.add_argument('--pg-database', default=os.environ.get('PGDATABASE', 'postgres'))
    parser.add_argument('--output-dir', type=Path, default=Path('/tmp/school-driver-comparison'))
    args = parser.parse_args()
    env = dict(os.environ, RAKUDO_RAKUAST='0')
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    data = dict(status='running', measured_at=time.strftime('%Y-%m-%d'),
                platform=platform.platform(), runtime=checked([args.raku, '--version'], env),
                source_sha256=source_fingerprint(), frontend='RAKUDO_RAKUAST=0', runs=[],
                postgres_connection=dict(host=args.pg_host, port=args.pg_port, user=args.pg_user,
                                         database=args.pg_database))
    try:
        psql(args, env, 'SELECT 1')
        with tempfile.TemporaryDirectory(prefix='redsourcing-school-comparison-') as temporary:
            directory = Path(temporary)
            for case in CASES:
                print(f'Warming {case}...', flush=True)
                data['runs'].append(run_case(args, env, case, True, 0, directory))
            for iteration in range(3):
                order = CASES[iteration:] + CASES[:iteration]
                for case in order:
                    row = run_case(args, env, case, False, iteration + 1, directory)
                    data['runs'].append(row)
                    print(f"round {iteration+1}: {case} {row['seconds']:.3f}s", flush=True)
        if source_fingerprint() != data['source_sha256']:
            raise RuntimeError('Demo/library sources changed during the comparison')
        for case in CASES:
            settings = [r['settings'] for r in data['runs'] if r['case'] == case]
            if any(item != settings[0] for item in settings):
                raise RuntimeError(f'{case}: effective settings changed between runs')
        if len({r['settings']['red_version'] for r in data['runs']}) != 1:
            raise RuntimeError('Scenarios used different Red versions')
        data['summary'] = summarize(data['runs'])
        data['red_version'] = data['runs'][0]['settings']['red_version']
        data['status'] = 'complete'
    except BaseException as error:
        data['status'] = 'failed'
        data['error'] = str(error)
        raise
    finally:
        (output / 'results.json').write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
        (output / 'comparison.md').write_text(markdown(data))
    print(f"Report: {output / 'comparison.md'}", flush=True)


if __name__ == '__main__':
    main()
