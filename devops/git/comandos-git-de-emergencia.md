# Comandos Git de emergência — desfazer o que deu errado

> O que rodar quando o commit foi para o lugar errado, o `reset --hard` levou trabalho junto,
> o merge saiu torto ou você precisa voltar para um estado que "sumiu".

| | |
|---|---|
| **Compatibilidade** | Git 2.23+ para `git switch` e `git restore`. Os demais comandos funcionam em Git 1.8+. |
| **Impacto** | Varia por comando — cada bloco declara o seu. Comandos que reescrevem histórico estão marcados com ⚠️. |
| **Pré-requisito** | Saber em que branch você está (`git status`) antes de qualquer coisa. |

---

## Problema

Erro em Git quase nunca é perda de dado — é dado que você não sabe mais onde encontrar. O Git
guarda praticamente tudo por 90 dias no `reflog`, mesmo o que parece apagado. O problema real é
que, sob pressão, a pessoa aplica um segundo comando destrutivo em cima do primeiro e aí sim
perde trabalho de verdade.

Este documento organiza os comandos por **sintoma**, com a regra de ouro antes de tudo.

---

## Regra de ouro antes de qualquer comando destrutivo

Antes de `reset --hard`, `rebase`, `checkout` que descarta alterações ou `push --force`:

```bash
# 1. Fotografe o estado atual. Isso custa 2 segundos e salva a noite.
git status
git log --oneline -10
git reflog -20

# 2. Se houver trabalho não commitado que você não quer perder:
git stash push -u -m "antes-de-mexer-$(date +%Y%m%d-%H%M)"
#   -u inclui arquivos nao rastreados (untracked). Sem ele, o stash os deixa para tras.
```

Se o trabalho não commitado for importante e você estiver com pressa, existe uma alternativa
ainda mais segura que o `stash`: **copie a pasta inteira**. É deselegante e funciona.

---

## Sintoma: "Fiz o commit e a mensagem está errada"

**Impacto:** reescreve o último commit. Seguro se o commit **ainda não foi enviado**.

```bash
git commit --amend -m "sql-server: corrige filtro de sessao na arvore de bloqueio"
```

Se já foi enviado para um branch compartilhado, **não faça amend**. Faça um commit novo. Corrigir
a mensagem de um commit público obriga todo mundo a reescrever o histórico local.

---

## Sintoma: "Esqueci um arquivo no commit"

```bash
git add caminho/do/arquivo-esquecido.sql
git commit --amend --no-edit    # --no-edit mantem a mensagem original
```

---

## Sintoma: "Commitei no branch errado"

O commit está em `main` e deveria estar em `feature/x`. Nada foi enviado ainda.

```bash
# 1. Anote o hash do commit que voce quer mover
git log --oneline -3

# 2. Crie o branch correto a partir de onde voce esta (ele leva o commit junto)
git branch feature/x

# 3. Volte o branch errado um commit para tras, preservando o working directory
git reset --hard HEAD~1     # ⚠️ so use --hard se nao houver alteracao nao commitada

# 4. Va para o branch certo
git switch feature/x
```

Se já existirem commits no branch de destino, use `cherry-pick`:

```bash
git switch feature/x
git cherry-pick <hash-do-commit>
git switch main
git reset --hard HEAD~1     # ⚠️ remove o commit do branch errado
```

---

## Sintoma: "Rodei `git reset --hard` e perdi commits"

**Não perdeu.** O `reflog` guarda para onde `HEAD` apontou nos últimos 90 dias (padrão de
`gc.reflogExpire`).

```bash
git reflog
```

Saída típica:

```text
a1b2c3d HEAD@{0}: reset: moving to HEAD~3
9f8e7d6 HEAD@{1}: commit: sql-server: adiciona script de memory grants
5c4b3a2 HEAD@{2}: commit: dotnet: documenta correlation id
```

O commit que você quer é `9f8e7d6`. Duas formas de recuperar:

```bash
# Opcao A — voltar o branch inteiro para la
git reset --hard 9f8e7d6

# Opcao B — mais segura: criar um branch novo apontando para o estado antigo,
#           sem mexer no branch atual
git branch recuperado 9f8e7d6
git switch recuperado
```

**Prefira a opção B.** Ela não destrói nada; você compara os dois estados com calma e decide.

O `reflog` é **local**. Se o repositório foi clonado de novo, o reflog do clone antigo é a única
cópia — não apague a pasta antiga antes de recuperar.

---

## Sintoma: "Descartei alterações não commitadas"

Aqui a notícia é pior: **arquivo modificado e nunca commitado não está no reflog**. O Git só
conhece o que entrou no banco de objetos.

Existe uma exceção importante: se você chegou a rodar `git add`, o conteúdo virou um *blob* e
pode ser recuperado.

```bash
# Lista objetos que nao pertencem a nenhum commit (danglings)
git fsck --lost-found

# Cada blob listado pode ser inspecionado:
git cat-file -p <hash-do-blob>
```

Os objetos ficam em `.git/lost-found/`. Isso funciona até o próximo `git gc` agressivo.

**Lição operacional:** `git add` frequente é barato e transforma trabalho não rastreado em
trabalho recuperável.

---

## Sintoma: "Preciso desfazer um commit que já foi enviado"

**Nunca reescreva histórico de branch compartilhado.** Use `revert`, que cria um commit novo
desfazendo as mudanças — o histórico continua linear e ninguém precisa reclonar.

```bash
# Desfaz um commit
git revert <hash>

# Desfaz um intervalo (do mais antigo ao mais novo, exclusivo na ponta esquerda)
git revert <hash-antigo>..<hash-novo>

# Desfaz um merge commit: -m 1 significa "mantenha a linha do primeiro pai",
# que normalmente e o branch de destino (main)
git revert -m 1 <hash-do-merge>
```

Atenção ao `revert` de merge: depois de revertê-lo, um novo merge do mesmo branch **não trará as
alterações de volta**, porque o Git considera que aquele conteúdo já foi integrado. Para reintegrar,
é preciso reverter o revert (`git revert <hash-do-revert>`).

---

## Sintoma: "O merge deu conflito e eu quero cancelar"

```bash
git merge --abort      # volta ao estado anterior ao merge
git rebase --abort     # equivalente durante um rebase
git cherry-pick --abort
```

Se o merge **já foi concluído** e você quer desfazê-lo antes de enviar:

```bash
git reset --hard ORIG_HEAD    # ⚠️ ORIG_HEAD guarda onde HEAD estava antes do merge
```

---

## Sintoma: "Preciso ver como o arquivo estava antes"

```bash
# Conteudo de um arquivo em um commit especifico
git show <hash>:caminho/do/arquivo.cs

# Historico de alteracoes daquele arquivo, com o diff
git log -p -- caminho/do/arquivo.cs

# Historico mesmo tendo havido rename
git log --follow -- caminho/do/arquivo.cs

# Quem alterou cada linha e em qual commit
git blame -w caminho/do/arquivo.cs
#   -w ignora alteracao que e so espaco em branco — evita que uma reformatacao
#      esconda o autor real da logica

# Restaurar apenas aquele arquivo, sem mexer no resto
git restore --source=<hash> -- caminho/do/arquivo.cs
```

---

## Sintoma: "Alguma coisa quebrou e eu não sei em qual commit"

`git bisect` faz busca binária no histórico. Em um repositório com 1000 commits, encontra o
culpado em cerca de 10 testes.

```bash
git bisect start
git bisect bad                 # o commit atual esta quebrado
git bisect good v1.4.0         # esta tag/commit sabidamente funcionava

# O Git faz checkout no meio. Voce testa e responde:
git bisect good      # ou
git bisect bad

# ... repita ate o Git apontar o commit culpado

git bisect reset     # volta ao branch original
```

Com um script de teste que retorna 0 para sucesso e diferente de 0 para falha, dá para
automatizar:

```bash
git bisect run dotnet test --filter FullyQualifiedName~PedidoTests
```

---

## Sintoma: "Meu branch está atrás do remoto e o push foi recusado"

```text
! [rejected] main -> main (fetch first)
```

Nunca resolva isso com `push --force`. Isso apaga o trabalho de outra pessoa no servidor.

```bash
git fetch origin
git log --oneline HEAD..origin/main    # o que existe la que nao existe aqui
git log --oneline origin/main..HEAD    # o que existe aqui que nao existe la

# Opcao A — histórico compartilhado, quer preservar tudo
git merge origin/main

# Opcao B — branch pessoal, quer histórico linear
git rebase origin/main
```

Quando o `push --force` for realmente necessário (branch pessoal, após rebase), use a versão
com trava:

```bash
git push --force-with-lease
```

`--force-with-lease` recusa o push se alguém tiver enviado algo ao branch depois do seu último
`fetch`. É a diferença entre "reescreva meu trabalho" e "reescreva o trabalho de quem quer que
tenha chegado antes".

---

## Sintoma: "Preciso do trabalho de outra pessoa que ainda não foi mergeado"

```bash
git fetch origin
git switch -c revisao-pr origin/feature/branch-da-pessoa
```

---

## Sintoma: "O `.gitignore` não está funcionando"

O `.gitignore` só afeta arquivos **não rastreados**. Se o arquivo já foi commitado uma vez, ele
continua sendo rastreado para sempre.

```bash
# Descobrir qual regra esta (ou nao esta) pegando o arquivo
git check-ignore -v caminho/do/arquivo

# Parar de rastrear sem apagar do disco
git rm --cached caminho/do/arquivo
git commit -m "chore: para de rastrear arquivo local de configuracao"
```

> Se o arquivo que vazou contém um segredo, **remover do rastreamento não basta** — o valor
> continua no histórico. Veja
> [remover-segredo-vazado-do-historico.md](remover-segredo-vazado-do-historico.md).

---

## Quando NÃO utilizar

| Comando | Não use quando |
|---|---|
| `commit --amend` | O commit já foi enviado a um branch compartilhado. |
| `reset --hard` | Existe alteração não commitada que importa. Faça `stash` antes. |
| `rebase` | O branch é compartilhado e outras pessoas já basearam trabalho nele. |
| `push --force` | Em qualquer situação. Use `--force-with-lease`. |
| `push --force-with-lease` | Em `main`, `master` ou qualquer branch protegido de release. |
| `git clean -fdx` | Sem antes rodar `git clean -nd` para ver o que seria apagado. Ele apaga arquivos não rastreados **e não há reflog para isso**. |

---

## Cuidados

- **`git clean -fdx` é o comando mais perigoso desta lista.** Ele apaga arquivos não rastreados,
  incluindo `appsettings.Development.json`, certificados locais e qualquer coisa ignorada pelo
  `.gitignore`. Não existe recuperação. Sempre rode `git clean -nd` (dry-run) primeiro.
- O `reflog` expira. O padrão é 90 dias para commits alcançáveis e **30 dias** para os que não são
  (`gc.reflogExpireUnreachable`). Recuperação não é eterna.
- `git gc --prune=now` remove imediatamente os objetos órfãos. Não rode isso enquanto estiver
  tentando recuperar alguma coisa.

---

## Segurança

Antes de qualquer `push`, releia o próprio diff:

```bash
git diff --staged
```

Isso é a primeira linha de defesa contra vazamento de credencial — o `.gitignore` é a segunda.
Um `Password=` real em um `appsettings.json` commitado é comprometimento imediato, mesmo em
repositório privado.

---

## Referências

- [Git — `git-reflog`](https://git-scm.com/docs/git-reflog)
- [Git — `git-revert`](https://git-scm.com/docs/git-revert)
- [Git — `git-bisect`](https://git-scm.com/docs/git-bisect)
- [Git — `git-push` (`--force-with-lease`)](https://git-scm.com/docs/git-push)
- [Git — `git-fsck`](https://git-scm.com/docs/git-fsck)

---

**Criado por Fábio Cerqueira**
