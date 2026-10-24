#!/usr/bin/env python3
"""Compare current Red CRUD with the pre-Red SQL paths in disposable stores.

The SQL baseline is reconstructed below because the example was introduced in
an uncommitted working tree. Only tweet-page and TweetIndex.APPLY differ; the
framework, schema, fixtures, reconstruction and business commands are identical.
No HTTP server or application database is accessed.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DOMAIN = ROOT / "examples/microblog/lib/Microblog/Domain.rakumod"
RAW_PAGE = '''sub tweet-page (Str $application, @authors, Int :$before = 0, Int :$limit = 50 --> Hash) {
    die "limit must be between 1 and 100" unless 1 <= $limit <= 100;
    die "before must be nonnegative" if $before < 0;
    my $db = journal-connection();
    my @values = $application, |@authors.unique;
    my @p = parameters($db, @values.elems.UInt);
    my $sql = 'SELECT tweet,author,body,published,position FROM microblog_tweet WHERE application = '
        ~ @p[0] ~ ' AND author IN (' ~ @p.skip(1).join(',') ~ ')';
    if $before { @values.push($before); $sql ~= ' AND position < ' ~ parameters($db, @values.elems.UInt).tail }
    @values.push($limit + 1);
    $sql ~= ' ORDER BY position DESC LIMIT ' ~ parameters($db, @values.elems.UInt).tail;
    my @rows = storage-query($db, $sql, |@values);
    my $more = @rows.elems > $limit;
    @rows.pop if $more;
    %(tweets => @rows.map({ %(id => .<tweet>, author => .<author>, text => .<body>,
        published-at => .<published>, cursor => .<position>.Int) }).Array,
        next => ($more ?? @rows.tail<position>.Int !! Nil))
}
'''
RAW_APPLY = '''        my $db = journal-connection();
        my @values = $!application-id, $e.tweet-id, $e.user-id, $e.text, $e.published-at, $e.StoredEvent.id;
        my @p = parameters($db, 6);
        storage-query($db, 'INSERT INTO microblog_tweet (application,tweet,author,body,published,position) VALUES ('
            ~ @p.join(',') ~ ') ON CONFLICT(application,tweet) DO NOTHING', |@values);
        my @existing = storage-query($db, 'SELECT author,body,published,position FROM microblog_tweet WHERE application = '
            ~ @p[0] ~ ' AND tweet = ' ~ @p[1], $!application-id, $e.tweet-id);
        die 'Conflicting tweet identity' unless @existing && @existing[0]<author> eq $e.user-id
            && @existing[0]<body> eq $e.text && @existing[0]<published> eq $e.published-at
            && @existing[0]<position>.Int == $e.StoredEvent.id'''


def baseline(source):
    start = source.index('sub tweet-page ')
    end = source.index('\naggregate User', start)
    source = source[:start] + RAW_PAGE + source[end:]
    start = source.index('        my $*RED-FALLBACK', source.index('projection TweetIndex'))
    end = source.index('\n    }\n', start)
    source = source[:start] + RAW_APPLY + source[end:]
    return 'use RedSourcing::Storage;\nuse RedSourcing::Service::Lease;\n' + source


class Worker:
    def __init__(self, variant, folder, source, args):
        folder.mkdir()
        library = folder / 'lib/Microblog'
        library.mkdir(parents=True)
        (library / 'Domain.rakumod').write_text(source)
        self.variant = variant
        self.log = (folder / 'stderr.log').open('w')
        self.process = subprocess.Popen([
            args.raku, '-I' + str(ROOT / 'lib'), '-I' + str(folder / 'lib'),
            str(ROOT / 'tools/benchmark-microblog.raku'), args.driver,
            args.database, str(folder), str(args.history)
        ], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, text=True, bufsize=1)
        self.ready = self.receive()
        assert self.ready.get('ready'), self.ready
        print(f'{args.driver} {variant}: fixture ready', flush=True)

    def receive(self):
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f'{self.variant} worker exited: {self.process.poll()}: '
                + Path(self.log.name).read_text())
        return json.loads(line)

    def request(self, **message):
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()
        return self.receive()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.write('{"operation":"quit"}\n')
            self.process.stdin.flush()
            self.process.wait(timeout=30)
        self.log.close()
        assert self.process.returncode == 0, self.variant


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raku', default='raku')
    parser.add_argument('--driver', choices=['SQLite', 'Pg'], default='SQLite')
    parser.add_argument('--database', default='postgres', help='Pg database; uses isolated schemas and normal libpq settings')
    parser.add_argument('--history', type=int, default=300)
    parser.add_argument('--publish', type=int, default=50)
    parser.add_argument('--reads', type=int, default=100)
    parser.add_argument('--pairs', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.history < 150 or min(args.publish, args.reads, args.pairs) < 1:
        parser.error('history must be >=150; publish, reads and pairs must be positive')
    source = DOMAIN.read_text()
    variants = {'sql': baseline(source), 'red': source}
    samples = {name: [] for name in variants}
    workers = {}
    with tempfile.TemporaryDirectory(prefix='microblog-perf-') as temp:
        folder = Path(temp)
        try:
            for name, code in variants.items():
                workers[name] = Worker(name, folder / name, code, args)
            for pair in range(args.pairs):
                order = ['sql', 'red'] if pair % 2 == 0 else ['red', 'sql']
                pages = {}
                for name in order:
                    result = workers[name].request(operation='measure', publish=args.publish,
                        reads=args.reads, label=f'round-{pair}')
                    pages[name] = result.pop('page')
                    samples[name].append(result['seconds'])
                    print(f'{args.driver} pair {pair+1} {name}: {result["seconds"]}', flush=True)
                assert pages['sql'] == pages['red'], 'Normalized page contents differ'
            profiles = {name: worker.request(operation='profile')['counts'] for name, worker in workers.items()}
            versions = {name: worker.ready for name, worker in workers.items()}
        finally:
            for worker in workers.values():
                worker.close()
            for name in workers:
                diagnostics = (folder / name / 'stderr.log').read_text()
                # Pg emits expected DROP SCHEMA cascade notices during cleanup.
                unexpected = [line for line in diagnostics.splitlines()
                    if line and not line.startswith(('NOTICE:', 'DETAIL:', 'drop cascades'))]
                if unexpected:
                    raise RuntimeError(f'{name} diagnostics: {unexpected}')
    totals = {name: {kind: statistics.median(x[kind] for x in values)
                    for kind in values[0]} for name, values in samples.items()}
    metrics = {}
    for kind in totals['sql']:
        count = args.publish if kind == 'publish' else args.reads
        metrics[kind] = dict(sql_ms=totals['sql'][kind]*1000/count,
            red_ms=totals['red'][kind]*1000/count,
            change_percent=(totals['red'][kind]/totals['sql'][kind]-1)*100,
            ratio=totals['red'][kind]/totals['sql'][kind])
    result = dict(measured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        driver=args.driver, configuration=dict(history=args.history, initial_seed_tweets=3,
            publish_per_round=args.publish, reads_per_kind_per_round=args.reads, pairs=args.pairs,
            page_size=50, warmup_publish=5, warmup_reads_per_kind=20),
        methodology='Two independent persistent workers/stores; fixture and warmup excluded; five alternating pairs by default; domain commands and projection reads, without HTTP; statement counters installed only after timings. Each round grows both stores equally. SQL baseline reconstructed from pre-Red reader/writer paths, with identical current framework and schema.',
        versions=versions, metrics=metrics, samples_seconds=samples,
        untimed_statement_counts_for_three_operations=profiles,
        domain_sha256={k:hashlib.sha256(v.encode()).hexdigest() for k,v in variants.items()},
        framework_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((ROOT/'lib').rglob('*.rakumod'))})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(metrics, indent=2), flush=True)


if __name__ == '__main__':
    main()
