# Checklist — instância SQL Server em produção

> Lista de verificação para uma instância que você acabou de herdar, ou para a revisão
> periódica de uma que você já mantém. Cada item tem um link para o documento que explica o
> porquê.

| | |
|---|---|
| **Quando aplicar** | Ao assumir uma instância; depois, trimestralmente |
| **Responsável** | DBA responsável pela instância |
| **Tempo estimado** | 2 a 4 horas na primeira vez |

---

## Backup e recuperação — comece por aqui

- [ ] **RPO e RTO acordados com o negócio** e documentados por escrito.
- [ ] Recovery model de cada banco coerente com o RPO declarado.
- [ ] Backup full periódico em todos os bancos de usuário, **e em `master`, `model` e `msdb`**.
- [ ] Backup de log na frequência do RPO, para todo banco em `FULL`.
- [ ] Todos os backups com `CHECKSUM`.
- [ ] Backups gravados **fora** do servidor de banco.
- [ ] Cópia fora do site principal.
- [ ] Retenção definida e limpeza automática funcionando (backup antigo enche disco).
- [ ] Alerta quando um backup **falha** — e alerta quando ele simplesmente **não roda**.
- [ ] **Restore testado**, com a data do último teste registrada.
- [ ] Procedimento de restore escrito, legível por quem estiver de plantão.

→ [`../sql-server/administracao/backup-e-restore.md`](../sql-server/administracao/backup-e-restore.md)

---

## Integridade

- [ ] `DBCC CHECKDB` roda periodicamente **e alguém confere o resultado**.
- [ ] `PAGE_VERIFY` em `CHECKSUM` em todos os bancos.
- [ ] ERRORLOG monitorado para os erros **823, 824 e 825**.
- [ ] Antivírus com exclusão para `.mdf`, `.ndf`, `.ldf`, `.bak` e `.trn`.
- [ ] Data do último `CHECKDB` limpo conferida (`DBCC DBINFO`).

→ [`../sql-server/administracao/dbcc-checkdb-integridade.md`](../sql-server/administracao/dbcc-checkdb-integridade.md)

---

## Configuração da instância

- [ ] `max server memory` com teto explícito, reservando memória para o sistema operacional.
- [ ] `cost threshold for parallelism` revisado — o padrão **5** é baixo demais para hardware atual.
- [ ] `max degree of parallelism` compatível com a topologia de núcleos e NUMA.
- [ ] `optimize for ad hoc workloads` avaliado.
- [ ] `backup compression default` habilitado, se a edição suportar.
- [ ] **Instant File Initialization** habilitado (acelera autogrow de dados e restore).
- [ ] `AUTO_SHRINK` **desligado** em todos os bancos.
- [ ] `AUTO_UPDATE_STATISTICS` ligado (ou rotina própria comprovadamente funcionando).

→ [`../sql-server/administracao/README.md`](../sql-server/administracao/README.md)

---

## Arquivos e crescimento

- [ ] Autogrow em **MB fixo**, nunca em percentual — dados e log.
- [ ] Incremento dimensionado (incremento pequeno gera muitos VLFs no log).
- [ ] Arquivos de dados e de log em volumes separados.
- [ ] `tempdb` com múltiplos arquivos de dados **do mesmo tamanho** e mesmo incremento.
- [ ] `tempdb` com **um só** arquivo de log.
- [ ] `tempdb` no disco mais rápido disponível, fora do volume de log dos bancos críticos.
- [ ] Espaço livre monitorado, com alerta antes de o disco encher.
- [ ] Nenhum job de `SHRINK` agendado.

→ [`../sql-server/troubleshooting/diagnosticar-tempdb.md`](../sql-server/troubleshooting/diagnosticar-tempdb.md) ·
[`../sql-server/administracao/shrink-quando-nao-usar.md`](../sql-server/administracao/shrink-quando-nao-usar.md)

---

## Manutenção

- [ ] Rotina de manutenção de índices com limiar por tamanho e por fragmentação.
- [ ] **Atualização de estatísticas incluída na rotina** — `REORGANIZE` não atualiza nada.
- [ ] Janela de manutenção definida e respeitada.
- [ ] Histórico de jobs do SQL Agent com expurgo (o `msdb` cresce sozinho).
- [ ] Alerta em falha de job.
- [ ] Índices duplicados e não utilizados revisados ao menos uma vez por ano.

→ [`../sql-server/indexes/manutencao-de-indices.md`](../sql-server/indexes/manutencao-de-indices.md)

---

## Segurança

- [ ] Lista de `sysadmin` curta, e você reconhece cada nome.
- [ ] Nenhuma aplicação conectando como `sa`.
- [ ] Nenhuma aplicação em `db_owner`.
- [ ] Permissões concedidas via **papel**, nunca direto ao usuário.
- [ ] `sa` desabilitado ou renomeado (com outro `sysadmin` funcionando antes).
- [ ] `xp_cmdshell` desabilitado, ou justificado por escrito.
- [ ] Sem usuários órfãos após restores.
- [ ] Logins de pessoas que saíram da empresa removidos.
- [ ] Criptografia de conexão avaliada.
- [ ] Auditoria de acesso a dados sensíveis, quando a regulação exigir.

→ [`../sql-server/administracao/permissoes-e-menor-privilegio.md`](../sql-server/administracao/permissoes-e-menor-privilegio.md)

---

## Monitoramento

- [ ] Alerta de espaço em disco, com folga para agir.
- [ ] Alerta de falha de backup e de job.
- [ ] Alerta de bloqueio prolongado.
- [ ] Alerta de deadlock (a `system_health` já captura; falta o alerta).
- [ ] Alerta de `log_reuse_wait_desc` diferente de `NOTHING` por muito tempo.
- [ ] Coleta histórica de tamanho de tabelas — sem série temporal não há análise de crescimento.
- [ ] **Query Store habilitado** nos bancos críticos (SQL Server 2016+).
- [ ] `Application Name` configurado na connection string de **todas** as aplicações.

→ [`../sql-server/monitoramento/README.md`](../sql-server/monitoramento/README.md)

---

## Preparação para incidente

- [ ] Scripts de diagnóstico acessíveis **sem depender de internet**.
- [ ] Quem tem `VIEW SERVER STATE` para diagnosticar sem ser `sysadmin`?
- [ ] Procedimento de escalonamento definido: quem chamar, em que ordem.
- [ ] Contato do fornecedor do ERP ou do sistema crítico à mão.
- [ ] Roteiro de diagnóstico conhecido pela equipe de plantão.

→ [`../sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md`](../sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md)

---

## Os cinco itens que mais causam incidente

Se só der tempo de verificar cinco coisas, verifique estas:

1. **Restore testado** — backup sem restore testado é esperança, não backup.
2. **Backup de log em bancos `FULL`** — sem ele o log cresce até encher o disco.
3. **`max server memory`** — padrão em servidor dedicado provoca disputa com o sistema operacional.
4. **Nenhum job de `SHRINK`** — fragmenta todos os índices semanalmente.
5. **`Application Name`** — sem ele, nenhum diagnóstico futuro consegue apontar o culpado.

---

**Criado por Fábio Cerqueira**
