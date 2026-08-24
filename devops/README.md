# DevOps — Git, GitHub Actions e deployment

> Como o código sai da máquina e chega em produção — e como voltar quando a chegada dá errado.

---

## Os três erros que transformam deployment em incidente

**1. Rollback que ninguém nunca executou.** Todo plano de deployment tem uma linha dizendo
"em caso de falha, rollback". Quase nenhum tem alguém que já cronometrou esse rollback em
homologação. Rollback não ensaiado é intenção, não é plano.

**2. Migração de banco tratada como detalhe do deployment da aplicação.** Voltar binário é
trivial. Voltar um `DROP COLUMN` com dado novo já gravado não é. A regra que resolve isso está
em [estratégias de deployment e rollback](deployment/estrategias-de-deployment-e-rollback.md):
toda mudança de esquema precisa ser retrocompatível com a versão anterior da aplicação.

**3. Segredo em repositório, descoberto meses depois.** O reflexo é apagar o arquivo e commitar
de novo — o que não remove nada. E a limpeza do histórico, por mais trabalhosa que seja,
**não é a remediação**: a remediação é rotacionar a credencial, e ela precisa acontecer primeiro.

---

## Conteúdo

### Git

| Documento | Resolve |
|---|---|
| [Comandos Git de emergência](git/comandos-git-de-emergencia.md) | Commit no branch errado, `reset --hard` que levou trabalho junto, merge para desfazer, push recusado, "quando isso quebrou?" |
| [Um segredo vazou em um commit](git/remover-segredo-vazado-do-historico.md) | Procedimento completo de resposta: rotação, verificação de uso, reescrita de histórico com `git-filter-repo` e prevenção |

### GitHub Actions

| Documento | Resolve |
|---|---|
| [Pipeline de CI para .NET](github-actions/pipeline-ci-dotnet.md) | Workflow de build e teste, cache de NuGet, teste que passa sem ter rodado, segredo no log, projeto .NET Framework em runner Windows |

### Deployment

| Documento | Resolve |
|---|---|
| [Estratégias de deployment e rollback](deployment/estrategias-de-deployment-e-rollback.md) | Expand/contract, blue-green, canário, feature flag, migração de banco no pipeline, critérios de rollback |

Ver também: [checklists operacionais](../checklists/).

---

## O mínimo que todo repositório .NET deveria ter

Se você só tem meia hora para melhorar a esteira de um projeto existente, esta é a ordem de
retorno sobre esforço:

1. **`.gitignore` cobrindo formatos de segredo** (`*.pfx`, `*.pem`, `.env`, `appsettings.Production.json`).
   Custo: 2 minutos.
2. **Secret scanning + push protection** ligados em *Settings → Code security*. Custo: 1 minuto,
   e é a única defesa que age **antes** do vazamento.
3. **`global.json` fixando a versão do SDK.** Elimina a classe inteira de "compilava semana
   passada".
4. **Workflow de CI rodando build e teste em Pull Request**, com `permissions: contents: read`
   no topo.
5. **Proteção de branch em `main`**: exigir Pull Request e exigir que o CI passe.
6. **Um artefato, promovido entre ambientes** — em vez de rebuild por ambiente.

Nada disso é sofisticado. O motivo de faltar quase sempre é que o projeto nasceu antes de a
esteira existir e ninguém voltou para arrumar.

---

## Navegação relacionada

- Problemas de aplicação depois do deployment: [`iis/troubleshooting/`](../iis/troubleshooting/)
  e [`dotnet/diagnostico/`](../dotnet/diagnostico/)
- Banco lento logo após subir versão: [`sql-server/troubleshooting/`](../sql-server/troubleshooting/)
  e [`sql-server/performance/`](../sql-server/performance/)
- Observabilidade para sustentar canário e janela de observação: [`dotnet/logging/`](../dotnet/logging/)
- Gestão de segredos na aplicação: [`api-integracao/autenticacao/`](../api-integracao/autenticacao/)

---

**Criado por Fábio Cerqueira**
