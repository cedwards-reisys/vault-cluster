// Vault Cluster - Cluster Status (scripted pipeline)
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

                stage('Cluster Status') {
                    withAwsAuth(envName, img) {
                        sh """
                            export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                                --secret-id ${clusterName}/vault/root-token \
                                --query SecretString --output text | jq -r '.token')

                            ./scripts/cluster-status.sh ${envName}
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
