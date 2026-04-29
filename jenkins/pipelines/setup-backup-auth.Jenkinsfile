// Vault Cluster - Setup Backup IAM Auth (scripted pipeline)
// Vault token fetched from AWS Secrets Manager at runtime.

def envName = env.JOB_NAME.split('/')[1]
def clusterName = "vault-${envName}"

node {
    timestamps {
        ansiColor('xterm') {
            try {
                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                def vaultAddr = ''
                def roleArn = ''
                withAwsAuth(envName, img) {
                    vaultAddr = sh(
                        script: "aws ssm get-parameter --name /${clusterName}/config/vault-url --query Parameter.Value --output text",
                        returnStdout: true
                    ).trim()
                    roleArn = sh(
                        script: "aws iam get-instance-profile --instance-profile-name ${clusterName}-vault-profile --query InstanceProfile.Roles[0].Arn --output text",
                        returnStdout: true
                    ).trim()
                }

                echo "Vault Address: ${vaultAddr}"
                echo "IAM Role ARN: ${roleArn}"

                stage('Approve') {
                    input message: "Set up backup IAM auth for ${envName}? This enables AWS auth method and creates a backup policy.", ok: 'Proceed'
                }

                stage('Setup') {
                    withAwsAuth(envName, img) {
                        sh """
                            export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                                --secret-id ${clusterName}/vault/root-token \
                                --query SecretString --output text | jq -r '.token')
                            export VAULT_ADDR=${vaultAddr}

                            vault auth enable aws 2>/dev/null || echo "AWS auth already enabled"

                            vault policy write backup - <<'POLICY'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Required by backup-snapshot.sh Raft-consensus leader check (C4).
path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}
POLICY
                            echo "Backup policy created."

                            echo "IAM Role ARN: ${roleArn}"

                            vault write auth/aws/role/backup \\
                                auth_type=iam \\
                                bound_iam_principal_arn="${roleArn}" \\
                                policies=backup \\
                                token_ttl=5m \\
                                token_max_ttl=10m

                            echo "AWS auth role 'backup' created."
                            echo "Setup complete. Automated backups can now authenticate."
                        """
                    }
                }
            } finally {
                cleanWs()
            }
        }
    }
}

def buildVaultOpsImage() {
    stage('Build Docker Image') {
        return docker.build("vault-ops:${env.BUILD_TAG}", ".")
    }
}
