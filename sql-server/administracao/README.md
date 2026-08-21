# SQL Server — Administração

> O que mantém a instância viva: backup, integridade, permissões e configuração. Área de
> decisões com consequência — quase tudo aqui altera estado.

---

## Documentos

| Documento | Assunto |
|---|---|
| [`backup-e-restore.md`](backup-e-restore.md) | RPO/RTO, recovery model, os três tipos de backup, roteiro de restore e os erros que aparecem no pior momento |
| [`dbcc-checkdb-integridade.md`](dbcc-checkdb-integridade.md) | Verificar corrupção antes que ela entre nos backups; o que fazer ao encontrar |
| [`permissoes-e-menor-privilegio.md`](permissoes-e-menor-privilegio.md) | Sair do `sa` sem derrubar o sistema; permissões de DBA sem ser `sysadmin` |
| [`shrink-quando-nao-usar.md`](shrink-quando-nao-usar.md) | Por que `SHRINK` como rotina é destrutivo, e os poucos casos em que se justifica |

---

## Configurações de instância que valem revisar

Cinco ajustes que aparecem repetidamente em instâncias herdadas.

```sql
SELECT
    configuracao = name,
    em_uso       = value_in_use,
    definido     = value,
    description
FROM sys.configurations
WHERE name IN ('max server memory (MB)',
               'min server memory (MB)',
               'max degree of parallelism',
               'cost threshold for parallelism',
               'optimize for ad hoc workloads',
               'backup compression default',
               'remote admin connections')
ORDER BY name;
```

| Configuração | O que costuma estar errado |
|---|---|
| `max server memory (MB)` | Deixada no padrão em servidor dedicado. O SQL Server tenta usar quase toda a memória e compete com o sistema operacional. Defina um teto explícito, reservando memória para o SO e para outros serviços da máquina |
| `cost threshold for parallelism` | O padrão é **5**, um valor calibrado para hardware dos anos 1990. Em servidores modernos faz o SQL Server paralelizar consultas triviais, gerando `CXPACKET` sem ganho. Elevar é um dos ajustes de melhor relação custo/benefício |
| `max degree of parallelism` | Padrão `0` (sem limite) em máquina com muitos núcleos costuma prejudicar carga OLTP. Configure conforme a orientação da Microsoft para a sua topologia de NUMA e número de núcleos |
| `optimize for ad hoc workloads` | Desligado em instâncias com muita query ad hoc, deixando o cache de planos inchar com planos de uso único |
| `backup compression default` | Desligado, mesmo quando a edição suporta. Ligar reduz espaço e costuma reduzir o tempo de backup |

> Nenhum desses valores tem número universal. Meça antes e depois, e mude um de cada vez —
> mudar três ao mesmo tempo torna impossível saber qual causou o efeito.

### Instant File Initialization

Permite que arquivos de **dados** cresçam sem zerar o espaço antes, o que acelera muito
autogrow e restore. Depende do privilégio *Perform volume maintenance tasks* concedido à
conta de serviço do SQL Server no Windows.

```sql
/* A partir do SQL Server 2016 o estado aparece aqui */
SELECT servicename, instant_file_initialization_enabled
FROM sys.dm_server_services;
```

**Não se aplica ao arquivo de log**, que sempre precisa ser zerado. Há uma implicação de
segurança conhecida: o espaço alocado pode conter resíduo de arquivos excluídos até ser
sobrescrito. Avalie no seu contexto.

---

## Comandos perigosos — leia antes

| Comando | Risco | Onde ler |
|---|---|---|
| `DBCC SHRINKDATABASE` / `SHRINKFILE` | Fragmenta todos os índices | [`shrink-quando-nao-usar.md`](shrink-quando-nao-usar.md) |
| `DBCC CHECKDB ... REPAIR_ALLOW_DATA_LOSS` | **Apaga dados** | [`dbcc-checkdb-integridade.md`](dbcc-checkdb-integridade.md) |
| `ALTER DATABASE ... SET RECOVERY SIMPLE` | Quebra a cadeia de backup | [`../troubleshooting/por-que-o-transaction-log-esta-crescendo.md`](../troubleshooting/por-que-o-transaction-log-esta-crescendo.md) |
| `KILL` | Rollback longo, perda de trabalho | [`../troubleshooting/matar-sessao-com-seguranca.md`](../troubleshooting/matar-sessao-com-seguranca.md) |
| `DBCC FREEPROCCACHE` | Recompilação em massa e pico de CPU | [`../troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md`](../troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) |
| `ALTER INDEX ... REBUILD` em tabela grande | Bloqueio e transaction log enorme | [`../indexes/manutencao-de-indices.md`](../indexes/manutencao-de-indices.md) |

---

## Áreas relacionadas

- [`../troubleshooting/`](../troubleshooting/) — diagnóstico durante incidente
- [`../indexes/`](../indexes/) — manutenção de índices
- [`../../checklists/`](../../checklists/) — listas de verificação operacionais

---

**Criado por Fábio Cerqueira**
