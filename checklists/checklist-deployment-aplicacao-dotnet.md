# Checklist — deployment de aplicação .NET

> Lista de verificação para ir a produção sem surpresa. Os critérios de rollback são a
> parte mais importante — e a que costuma ser definida durante o incidente, quando ninguém
> decide bem.

| | |
|---|---|
| **Quando aplicar** | Antes de cada deploy em produção |
| **Responsável** | Quem executa o deploy |
| **Tempo estimado** | 15 a 30 minutos |

---

## Antes do deploy

### Código e build

- [ ] Build limpo, sem avisos novos.
- [ ] Testes automatizados passando.
- [ ] Revisão de código concluída.
- [ ] Versão etiquetada no controle de versão (você vai precisar dela para o rollback).
- [ ] Dependências sem vulnerabilidade conhecida (`dotnet list package --vulnerable`).

### Configuração

- [ ] Connection strings do ambiente **de destino** conferidas.
- [ ] Segredos vindos de cofre ou variável de ambiente — **nada no repositório**.
- [ ] `ASPNETCORE_ENVIRONMENT` correto.
- [ ] `EnableSensitiveDataLogging` **desligado**.
- [ ] `customErrors mode` e `httpErrors errorMode` **não** estão em detalhado.
- [ ] `stdoutLogEnabled` **desligado**.
- [ ] Timeouts definidos conscientemente: `HttpClient.Timeout`, `CommandTimeout`.
- [ ] `Application Name` na connection string.

### Banco de dados

- [ ] Script de migração **revisado por outra pessoa**.
- [ ] Migração testada em ambiente com **volume comparável** ao de produção.
- [ ] Tempo de execução da migração estimado.
- [ ] Migração **retrocompatível** com a versão atual da aplicação (permite rollback do código sem reverter o banco).
- [ ] Script de rollback do banco escrito **e testado**.
- [ ] Backup full recente confirmado — e restaurável.
- [ ] Nenhum `MigrateAsync()` automático na inicialização.

> **Retrocompatibilidade é o que torna o rollback possível.** Adicionar coluna anulável é
> seguro; remover coluna ou renomear no mesmo deploy do código, não. Separe em dois deploys:
> primeiro o banco aceita as duas formas, depois o código migra, e só no terceiro a forma
> antiga é removida.

### Infraestrutura

- [ ] Runtime .NET presente no servidor, na versão certa (`dotnet --list-runtimes`).
- [ ] .NET Hosting Bundle atualizado, se for IIS.
- [ ] Certificados válidos e com prazo confortável.
- [ ] Permissões de pasta para a identidade do Application Pool.
- [ ] Espaço em disco suficiente.
- [ ] Health check respondendo e configurado no balanceador.

---

## Critérios de rollback — defina **agora**, não depois

| Gatilho | Ação |
|---|---|
| Taxa de erro acima de X% por Y minutos | **Rollback imediato** |
| Latência p95 acima de X ms por Y minutos | Avaliar em N minutos, depois rollback |
| Health check falhando | Rollback imediato |
| Erro em funcionalidade crítica de negócio | Rollback imediato |
| Consumo de memória crescendo de forma anômala | Monitorar; rollback se não estabilizar |

Preencha os X e os Y com números reais **antes** do deploy. Um critério sem número não é
critério: é opinião sob pressão.

---

## Durante o deploy

- [ ] Janela combinada e comunicada.
- [ ] Quem executa e quem acompanha, definidos.
- [ ] Aplicação retirada do balanceador antes da troca (se houver).
- [ ] Migração de banco aplicada e conferida.
- [ ] Artefatos publicados.
- [ ] Aplicação iniciada e health check verde.
- [ ] Fumaça: login, uma consulta, uma gravação, uma integração.
- [ ] Aplicação devolvida ao balanceador.

---

## Depois do deploy

### Primeiros 15 minutos

- [ ] Taxa de erro comparada com a linha de base anterior.
- [ ] Latência p95 e p99 comparadas.
- [ ] Log de exceções sem erro novo.
- [ ] Consumo de memória e de CPU dentro do esperado.
- [ ] Conexões de banco dentro do normal — [`../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql`](../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql).
- [ ] Nenhum bloqueio novo — [`../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql`](../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql).

### Primeiras 2 horas

- [ ] Memória estável (vazamento aparece nesta janela).
- [ ] Integrações externas funcionando.
- [ ] Jobs agendados executando normalmente.
- [ ] Nenhum aumento de deadlock — [`../sql-server/troubleshooting/extrair-deadlocks-do-system-health.sql`](../sql-server/troubleshooting/extrair-deadlocks-do-system-health.sql).

### Primeiro dia útil completo

- [ ] Rotinas noturnas concluídas com sucesso.
- [ ] Relatórios e fechamentos conferidos.
- [ ] Nenhuma query nova no topo do consumo — [`../sql-server/performance/queries-que-mais-consomem-cpu.sql`](../sql-server/performance/queries-que-mais-consomem-cpu.sql).
- [ ] Crescimento de arquivos dentro do previsto.

---

## Se algo der errado

1. **Avaliar contra os critérios definidos acima.** Não improvise.
2. **Preservar evidência antes de reverter**: log, dump, estado das sessões no banco,
   horário exato. Depois do rollback, a evidência some.
3. **Executar o rollback** — código primeiro; banco só se for indispensável.
4. **Comunicar**: o que aconteceu, o que foi feito, qual o estado atual.
5. **Registrar para o pós-incidente**, sem procurar culpado.

> Se a migração de banco foi retrocompatível, o rollback é apenas voltar a versão do
> código — rápido e seguro. Esse é exatamente o motivo de exigir retrocompatibilidade.

---

## Os cinco itens que mais salvam deploy

1. **Migração de banco retrocompatível** — torna o rollback trivial.
2. **Critérios de rollback com número**, definidos antes.
3. **Backup confirmado e restaurável** antes de tocar no banco.
4. **Health check real**, que exercita banco e dependências — não um endpoint que devolve `OK` fixo.
5. **Linha de base de métricas** antes do deploy: sem ela não dá para saber se piorou.

---

**Criado por Fábio Cerqueira**
