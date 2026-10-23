# Comando e emissão de eventos: sequência medida

Amostra: primeira matrícula de Alice em class-1 no demo real da escola. SQLite em memória,
RAKUDO_RAKUAST=0, 2026-10-20. Uma execução instrumentada após aquecimento,
com saída conferida contra a execução sem instrumentação. Não é uma mediana por comando.

Tempos inclusivos: filhos já estão no tempo do pai. Os blocos de preparação são intervalos
entre os pontos observados, incluindo o trabalho Raku desse intervalo. O restante de filtros
inclui análise de dependências, varreduras do AST e outros preparos não cronometrados
separadamente. SQL é tempo ativo de preparar/executar/ler no driver, não o tempo total de
uma consulta Red. Hidratação, COERCE e handlers são mostrados separadamente.

```mermaid
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

    Note over App,DB: alice em class-1 — total 378.34 ms
    App->>DB: Buscar snapshot e preparar stream — 19.30 ms
    opt Primeiro uso do stream
        App->>DB: BEGIN — 0.27 ms
        App->>A: Criar snapshot inicial — 6.28 ms
        A->>J: Append do snapshot — 5.43 ms
        Note over J,K: Sem decisão ativa, lote vazio de contadores, sem SQL de CAS
        App->>DB: COMMIT — 0.37 ms
    end
    App->>C: Persistir Pending — 5.34 ms
    Note over C,DB: Inclui BEGIN, INSERT do comando e COMMIT
    App->>C: run — 345.69 ms
    C->>DB: Atualizar a cópia local do comando — 4.21 ms
    C->>DB: BEGIN de execução — 0.16 ms
    C->>DB: Claim Pending para Processing, SQL — 0.22 ms
    C->>DB: Recarregar estado após o claim — 7.82 ms
    C->>A: Carregar agregado — 14.21 ms
    Note over A,DB: Snapshot, COERCE e replay do stream
    A-->>C: Agregado restaurado
    C->>A: Preparar e executar enroll — 314.43 ms
    A->>D: decision-model — 314.14 ms
    D->>D: Preparar IDs e escopo — 4.01 ms
    D->>DB: SAVEPOINT — 0.53 ms
    D->>D: Preparar filtros e dependências — 97.49 ms
    Note over D: Assinaturas 1.50 ms, predicados 32.54 ms, restante 63.45 ms
    D->>K: Ler versões das dependências — 1.31 ms
    D->>D: Instanciar views e preparar consulta Red — 181.53 ms
    rect rgb(245,248,255)
        Note over D,P: Consulta e reconstrução — 6.22 ms, incluindo SQL
        D->>DB: SELECT combinado por OR, driver — 0.75 ms
        D->>D: Hidratar as duas linhas — 1.84 ms
        D->>D: COERCE dos eventos — 2.32 ms
        D->>P: APPLY dos eventos anteriores — 0.23 ms
    end
    D->>A: Registrar decisão, validar limites e preparar evento — 1.64 ms
    rect rgb(240,250,240)
        Note over A,DB: Emissão observada, normalização até hooks — 7.00 ms
        A->>A: Normalizar payload JSON — 0.07 ms
        A->>K: Gerar chaves das tags — 0.17 ms
        A->>J: Append StudentEnrolled — 6.71 ms
        J->>K: Calcular condições da decisão — 0.64 ms
        J->>K: CAS otimista em lote — 0.88 ms
        Note over K,DB: Validar versões e incrementar contadores na mesma transação
        J->>DB: Criar StoredEvent pelo Red — 4.63 ms
        Note over J,DB: Inclui INSERT RETURNING, 0.38 ms ativos no driver
        J->>P: Verificar projections transacionais — 0.18 ms
        Note over P: Nenhuma projection transacional é atualizada neste exemplo
    end
    A->>A: COERCE do novo evento — 0.17 ms
    A->>A: APPLY StudentEnrolled, active=True — 0.09 ms
    A->>A: Versão, cursor, publicação e retorno do bloco, restante — 1.34 ms
    Note over A: active=True, versão, cursor e publicação provisória, inclusos nos blocos externos
    A-->>D: True
    D->>DB: RELEASE SAVEPOINT — 0.49 ms
    D->>D: Finalizar escopo da decisão — 12.32 ms
    D-->>A: True
    A-->>C: True
    C->>C: Verificar auto-snapshot e preparar finalização — 0.63 ms
    C->>DB: Salvar Done e resultado — 2.14 ms
    Note over C: Nenhum novo snapshot automático, limite ainda não atingido
    C->>DB: COMMIT de execução — 0.18 ms
    C-->>App: True
```

O caminho completo levou **378.34 ms**, dos quais **345.69 ms**
dentro de `StoredCommand.run` e **314.14 ms** dentro de `decision-model`.
Os **22 statements** somaram **5.55 ms** ativos no driver.
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
