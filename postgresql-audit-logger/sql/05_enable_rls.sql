-- Etapa 5: Row-Level Security (opcional)
ALTER TABLE audit.log_usuarios ENABLE ROW LEVEL SECURITY;

CREATE POLICY log_visualizacao_apenas_leitura
ON audit.log_usuarios
FOR SELECT
TO PUBLIC
USING (true);