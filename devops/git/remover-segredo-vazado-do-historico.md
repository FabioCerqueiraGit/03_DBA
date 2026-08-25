# Um segredo vazou em um commit — o que fazer

> Procedimento de resposta a incidente para senha, connection string, token ou chave privada
> enviados por engano ao Git.

| | |
|---|---|
| **Compatibilidade** | Git 2.22+. `git-filter-repo` exige Python 3.6+. |
| **Impacto** | **Alto.** Reescreve todo o histórico do repositório e obriga todos os clones a serem refeitos. |
| **Urgência** | Máxima. A primeira ação não é técnica — é rotacionar a credencial. |

---

## Problema

Alguém commitou um `Password=` com valor real em um `appsettings.json`, ou uma `.pfx`, ou um token
de API. O commit foi enviado. O reflexo natural é apagar o arquivo e commitar de novo.

**Isso não resolve nada.** O valor continua no histórico, acessível por:

```bash
git log -p --all -S "Password=" | less
```

Qualquer pessoa com acesso de leitura ao repositório — hoje ou daqui a três anos — encontra o
valor em segundos. Se o repositório for público, assuma que já foi coletado: existem varredores
automatizados que monitoram o event stream público do GitHub e testam credenciais em minutos.

---

## A ordem correta das ações

A sequência importa. Fazer a limpeza do histórico antes de rotacionar a credencial é o erro
clássico: gasta-se uma hora reescrevendo o repositório enquanto a senha continua válida.

### Passo 1 — Rotacione a credencial. Agora.

| O que vazou | Ação imediata |
|---|---|
| Senha de login SQL Server | `ALTER LOGIN [<login>] WITH PASSWORD = '<nova-senha>';` e atualize o segredo na aplicação |
| Token de API / PAT do GitHub | Revogue no provedor. Não "expire": **revogue**. |
| Client secret de OAuth / Entra ID | Gere um novo, atualize a aplicação, remova o antigo |
| Certificado `.pfx` / `.p12` | Revogue o certificado na CA e emita outro |
| Chave SSH privada | Remova a pública correspondente de todos os `authorized_keys` e do GitHub |
| Connection string com credencial | Rotacione a credencial e considere migrar para autenticação integrada ou Managed Identity |
| Chave de conta de storage | Rotacione a chave; prefira SAS com escopo e validade curtos |

**Considere o segredo comprometido, sem discussão.** Não existe "vazou só por 10 minutos" e não
existe "o repositório é privado, então tudo bem" — repositório privado tem colaboradores, forks
internos, backups, CI com cache e espelhos.

### Passo 2 — Verifique o uso indevido

Antes de limpar as evidências, olhe os logs:

- SQL Server: logins do login comprometido em `sys.event_log` (Azure SQL) ou no ERRORLOG /
  auditoria, se a auditoria de login estiver ligada.
- GitHub: **Settings → Security log** da organização.
- Provedor de nuvem: sign-in logs / trilha de auditoria para o principal afetado.

Registre o que encontrou. Se houver indício de uso, isso deixa de ser um problema de Git e vira
um incidente de segurança formal.

### Passo 3 — Só então limpe o histórico

E mesmo aqui: limpar o histórico é **higiene**, não remediação. A remediação foi o passo 1.

---

## Solução — reescrever o histórico com `git-filter-repo`

O GitHub recomenda `git-filter-repo`. `git filter-branch` está obsoleto (é lento, tem armadilhas
sutis e o próprio Git desencoraja o uso).

### Instalação

```bash
pip install git-filter-repo
# ou, no Windows com Python instalado:
py -m pip install git-filter-repo
```

### Caso A — o segredo está em um arquivo inteiro que não deveria existir

Exemplo: `src/Api/appsettings.Production.json` ou `certificados/producao.pfx`.

```bash
# 1. Trabalhe sobre um clone novo e completo. Nao faca isso no seu clone de trabalho.
git clone --mirror https://github.com/<ORG>/<REPO>.git repo-limpeza
cd repo-limpeza

# 2. Remova o arquivo de todo o historico
git filter-repo --invert-paths --path src/Api/appsettings.Production.json
```

O parâmetro `--invert-paths` inverte o sentido do filtro: em vez de "mantenha só estes caminhos",
passa a significar "remova estes caminhos".

### Caso B — o segredo é um valor dentro de um arquivo que deve permanecer

Exemplo: uma connection string dentro de um `web.config` que continua sendo necessário.

Crie um arquivo de substituições (fora do repositório, para não commitá-lo junto):

```text
# ../substituicoes.txt
<VALOR-DA-SENHA-QUE-VAZOU>==><SENHA>
<VALOR-DO-TOKEN-QUE-VAZOU>==><TOKEN>
regex:Password=[^;"]+==>Password=<SENHA>
```

O separador é `==>`. Cada linha é `valor-original==>substituto`; o valor original é o texto real
que vazou, digitado literalmente. O prefixo `regex:` habilita expressão regular — útil quando o
mesmo segredo aparece em variações.

```bash
git filter-repo --replace-text ../substituicoes.txt
```

> **Não deixe o arquivo de substituições no repositório, e apague-o ao terminar.** Ele é, por
> construção, uma lista de segredos reais em texto claro.

### Passo 4 — Envie o histórico reescrito

```bash
git push --force --mirror origin
```

⚠️ Isso reescreve **todos** os refs do remoto. Combine com a equipe antes. Se o branch estiver
protegido, será necessário desprotegê-lo temporariamente.

### Passo 5 — Todo mundo reclona

Não peça para a equipe fazer `pull`. O histórico local delas ainda contém o segredo e um `pull`
mal resolvido pode reintroduzi-lo.

```bash
# A instrucao para o time e:
# 1. Salve qualquer trabalho local (branch, patch, ou copia da pasta)
# 2. Apague a pasta do repositorio
# 3. Clone de novo
```

Se alguém tiver branch local não enviado, o caminho é gerar patches antes:

```bash
git format-patch origin/main --stdout > ../meu-trabalho.patch
# depois do reclone:
git am ../meu-trabalho.patch
```

### Passo 6 — Peça a limpeza dos caches do GitHub

Reescrever o histórico **não remove**:

- as visualizações de diff em cache de Pull Requests;
- referências internas do GitHub que ainda apontam para os commits antigos.

Segundo a documentação do GitHub, é preciso abrir um chamado no
[GitHub Support portal](https://support.github.com/) para que essas visualizações em cache sejam
removidas e os Pull Requests afetados sejam desreferenciados. O próprio GitHub declara que só
auxilia na remoção de dados sensíveis quando o risco não pode ser mitigado pela rotação da
credencial — ou seja, o passo 1 continua sendo o que realmente importa.

---

## Quando NÃO reescrever o histórico

| Situação | Por quê |
|---|---|
| A credencial já foi rotacionada e o repositório é interno com auditoria de acesso | O valor antigo virou lixo. Reescrever custa caro (todos reclonando) e entrega pouco. |
| O "segredo" era um placeholder ou credencial de ambiente descartável de teste | Não havia risco. |
| Há dezenas de Pull Requests abertos | A reescrita quebra as bases deles. Feche ou mergeie antes, ou agende para uma janela. |
| Você não consegue coordenar o reclone de toda a equipe hoje | Reescrita parcialmente adotada gera histórico divergente e reintrodução acidental do segredo. |

Nesses casos, documente a decisão: credencial rotacionada em `<data>`, valor antigo permanece no
histórico, risco aceito. Decisão registrada é decisão; decisão implícita é omissão.

---

## Prevenção — o que impede o próximo vazamento

### 1. `.gitignore` que cobre os formatos de segredo

```gitignore
# Segredos e credenciais
*.pfx
*.p12
*.key
*.pem
appsettings.*.local.json
appsettings.Production.json
secrets.json
.env
.env.*
*.publishsettings
*.pubxml.user
```

### 2. Configuração fora do código

- **.NET Core / .NET 5+ em desenvolvimento:** User Secrets. O arquivo fica no perfil do usuário,
  fora da pasta do projeto — não há como commitá-lo por acidente.

```bash
dotnet user-secrets init
dotnet user-secrets set "ConnectionStrings:Principal" "Server=<SERVIDOR>;Database=<BANCO>;Integrated Security=true;Encrypt=True;TrustServerCertificate=False"
```

- **.NET Framework:** o `web.config` aceita externalizar seções para arquivo não versionado:

```xml
<!-- web.config versionado -->
<connectionStrings configSource="connections.config" />
<!-- connections.config fica no .gitignore e e provisionado pelo deployment -->
```

- **Produção, em qualquer plataforma:** variáveis de ambiente, Azure Key Vault, AWS Secrets
  Manager ou o cofre da sua organização. E, quando o destino for SQL Server em ambiente com
  Active Directory, **autenticação integrada elimina a senha do problema**. Detalhes em
  [`../../seguranca/secrets/`](../../seguranca/secrets/gerenciamento-de-segredos-em-aplicacoes-dotnet.md).

### 3. Push protection do GitHub

Em **Settings → Code security**, habilite *Secret scanning* e *Push protection*. Com push
protection ligada, o GitHub bloqueia o `push` que contém um padrão de segredo conhecido —
a defesa acontece antes do vazamento, não depois.

### 4. Hook local

Um `pre-commit` simples pega os casos óbvios:

```bash
#!/bin/sh
# .git/hooks/pre-commit  (chmod +x)
if git diff --cached -U0 | grep -nEi '(password|pwd|senha)\s*=\s*[^;<"\s]|ghp_[A-Za-z0-9]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'; then
  echo "ERRO: possivel segredo no commit. Revise as linhas acima."
  echo "Se for falso positivo: git commit --no-verify"
  exit 1
fi
```

Hook local não é controle — a pessoa pode ignorá-lo com `--no-verify` e ele não existe em clones
novos. Ele é conveniência. O controle é a push protection do lado do servidor.

---

## Checklist do incidente

- [ ] Credencial rotacionada/revogada no provedor de origem.
- [ ] Aplicações que usavam a credencial atualizadas e validadas.
- [ ] Logs de acesso verificados no período entre o vazamento e a rotação.
- [ ] Decisão registrada: histórico foi reescrito ou risco foi formalmente aceito.
- [ ] Se reescrito: equipe avisada e clones refeitos.
- [ ] Se reescrito: arquivo de substituições apagado.
- [ ] Se reescrito: chamado aberto no suporte do GitHub para caches de PR.
- [ ] `.gitignore` atualizado para bloquear o formato que vazou.
- [ ] Secret scanning e push protection habilitados no repositório.
- [ ] Segredo migrado para User Secrets / cofre / variável de ambiente.

---

## Referências

- [GitHub — Removing sensitive data from a repository](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
- [GitHub — Push protection for repositories](https://docs.github.com/en/code-security/secret-scanning/introduction/about-push-protection)
- [`git-filter-repo`](https://github.com/newren/git-filter-repo)
- [Microsoft Learn — Safe storage of app secrets in development in ASP.NET Core](https://learn.microsoft.com/aspnet/core/security/app-secrets)

---

**Criado por Fábio Cerqueira**
