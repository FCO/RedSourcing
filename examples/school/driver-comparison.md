# Demo school: SQLite e PostgreSQL

Medição local de 2026-10-20, demo completo sem instrumentação.

Um aquecimento por cenário, seguido de três rodadas em ordem alternada. Cada execução começa vazia. O tempo é do processo completo: carregamento dos módulos, conexão, tabelas/índices e operações do demo. Preparação do schema PostgreSQL e inicialização do servidor ficam fora do cronômetro.

| Cenário | Execuções (s) | Mediana (s) | Mínimo–máximo (s) |
| --- | --- | ---: | --- |
| sqlite-memory | 17.386, 17.630, 17.626 | 17.626 | 17.386–17.630 |
| sqlite-file | 17.717, 17.835, 18.304 | 17.835 | 17.717–18.304 |
| postgresql | 18.411, 18.497, 18.502 | 18.497 | 18.411–18.502 |

Comparação de tempos do PostgreSQL:

- Em relação a sqlite-memory: tempo **4.9% maior**, razão **1.049×**.
- Em relação a sqlite-file: tempo **3.7% maior**, razão **1.037×**.

SQLite em arquivo versus PostgreSQL compara os dois caminhos persistentes. SQLite em memória representa o demo padrão. PostgreSQL usa TCP local; SQLite está embutido no processo. Os resultados incluem essas diferenças. Não houve alteração de configuração para desabilitar durabilidade.

Todas as saídas foram idênticas: Alice termina com dez aulas, matemática com trinta alunos, duas rejeições esperadas e quarenta matrículas ativas no replay final.

## Configuração observada

| Cenário | Versão do banco | Configurações efetivas |
| --- | --- | --- |
| sqlite-memory | 3.51.0 | journal_mode=memory, synchronous=2 |
| sqlite-file | 3.51.0 | journal_mode=delete, synchronous=2 |
| postgresql | 18.4 (Homebrew) | fsync=on, synchronous_commit=on, full_page_writes=on |

`synchronous=2` corresponde a FULL no SQLite; em memória não há arquivo durável. As configurações foram consultadas fora do cronômetro usando o mesmo driver Red. O tracing mantém o valor da configuração original, sem reconstruir flow ou métricas.

Red: **0.2.7**. Plataforma: macOS-26.5.2-arm64-arm-64bit-Mach-O. Frontend: `RAKUDO_RAKUAST=0`.

```text
Welcome to Rakudo™ v2026.09-198-g50379ea28a.
Implementing the Raku® Programming Language v6.d.
Built on MoarVM version 2026.09-38-g597c5351b.
```

## Reprodução

Com um PostgreSQL local já iniciado:

```sh
python3 tools/compare-school-drivers.py --pg-host=127.0.0.1 --pg-port=5432 \
  --pg-user=postgres --pg-database=postgres --output-dir=/tmp/school-driver-comparison
```

O script aceita `--raku` para selecionar o executável. Bibliotecas nativas e autenticação seguem o ambiente local. Ele cria/remove somente seus próprios schemas e arquivos temporários, sem iniciar ou parar o servidor. O JSON gerado contém os tempos individuais, configurações e a impressão digital dos fontes medidos.
