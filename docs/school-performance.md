# Onde o school ainda gasta tempo

Medição local em 2026-10-21, Red 0.2.7, Rakudo 2026.09, SQLite em memória,
precomp aquecido e configuração normal de flow tracing. O demo completo executa
90 comandos, com duas rejeições esperadas, e termina com 40 matrículas ativas.

A mediana de três processos sem instrumentação foi **5.992 s**.
O processo instrumentado representativo levou 6.488 s;
os tempos abaixo pertencem a essa amostra e são inclusivos. Eles se sobrepõem e
não devem ser somados.

| Estágio | Chamadas | Tempo inclusivo |
| --- | ---: | ---: |
| `Decision.model` | 44 | 1.258 s |
| `Storage.create` | 264 | 1.000 s |
| `Storage.hydrate` | 1050 | 0.735 s |
| `Storage.save` | 444 | 0.529 s |
| `Entity.create` | 86 | 0.515 s |
| `Command.refresh` | 90 | 0.373 s |
| `Storage.decision-rows` | 44 | 0.456 s |

As **1646 execuções SQL** somaram **0.316 s** no driver
(preparar, executar e ler linhas). Isso não inclui a montagem das consultas Red,
hidratação dos modelos nem o restante do processamento Raku.

## Verificação de existência do stream

`School.ensure` monta uma consulta Red com filtro por classe e stream antes de
cada comando. Uma execução com cronômetro apenas nessa função somou
1.680 s em 90 chamadas. Esse número inclui a
criação dos 86 snapshots iniciais; não representa apenas SELECTs.

Para testar a hipótese de custo de montagem da consulta, uma cópia temporária
substituiu a expressão Red por `storage-prepared-query` com o mesmo predicado e
`LIMIT 1`. Ela continuou consultando o banco em cada chamada e criando os mesmos
streams. Não foi usado cache de resultados ou de existência.

| Demo completo, sem instrumentação | Mediana de 3 processos |
| --- | ---: |
| Código atual | 6.072 s |
| Variante temporária com SELECT preparado | 4.534 s |
| Diferença | -25.3% |

Houve um aquecimento de cada variante e três pares em ordem alternada, sem outros
benchmarks concorrentes. As saídas foram idênticas, incluindo as duas rejeições e
as 40 matrículas finais. A variante é apenas uma prova local em SQLite; não foi
aplicada à biblioteca nem validada em Pg. O próximo passo mais direto é oferecer
um helper interno de existência com binds para os drivers suportados e usá-lo
no exemplo, preservando consulta atual ao banco e validação de criação concorrente.

## Replay e hidratação

As 44 decisões retornaram **650 linhas históricas**.
O SELECT da turma de matemática cresce de 2 até 33 linhas ao longo do demo.
O exemplo cria snapshots iniciais dos agregados, mas não checkpoints de
`StudentClasses` e `ClassRoster`. O suporte a checkpoints no decision-model está
presente; ele não elimina replay quando não há checkpoint dessas projections.

Depois da consulta de existência, os próximos candidatos são:

- Reutilizar o estado reconstruído das projections com validação de versões e
  cursor, isolamento transacional e replay apenas da cauda. O cache atual de
  templates não guarda esse estado.
- Reduzir materialização e conversão de registros de comandos/eventos. Foram
  observadas 1.050 hidratações; reutilizar apenas o statement não elimina esse custo.

## Verificação e limites

O medidor foi corrigido para observar o handle SQLite nativo: reutilizações agora
criam um registro SQL novo, com o pai atual. Antes ele contava preparações e
perdia execuções do pool. O relatório de comando também foi ajustado para a linha
`RETURNING` do claim, que já substitui o segundo refresh.

O script de profiling completou três execuções normais e três instrumentadas,
conferindo stdout. `python3 -m py_compile` e `git diff --check` passaram.
A tentativa de usar o profiler da VM abortou com `Profiler lost sequence` durante
uma rejeição capturada; estes resultados usam os cronômetros de estágios.
Nenhum comportamento de produção foi alterado nesta investigação.

[Dados, amostras e hashes das fontes](../examples/school/current-hotspots.json).

Para repetir a medição dos estágios:

```sh
python3 tools/profile-school-demo.py --runs=3 --output-dir=/tmp/school-current-profile
```


## Implementation after this investigation

The prepared existence helper has now been implemented for SQLite and Pg and
is used by School. The final five-pair comparison changed the SQLite median
from **5.973 s to 4.542 s (-24.0%)**, with all outputs matching.
See [implementation and validation](performance.md#prepared-stream-existence-reads)
and [raw samples](../examples/school/stream-existence-comparison.json).
