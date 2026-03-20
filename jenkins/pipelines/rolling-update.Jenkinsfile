// Vault Cluster - Rolling Update (scripted pipeline)
// Vault token fetched from AWS Secrets Manager at runtime.

def envName = env.JOB_NAME.split('/')[1]
def clusterName = "vault-${envName}"

properties([
    parameters([
        booleanParam(name: 'SKIP_TERRAFORM', defaultValue: false, description: 'Skip tofu apply (node replacement only)')
    ])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()
                def fetchToken = """
                    export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                        --secret-id ${clusterName}/vault/root-token \
                        --query SecretString --output text | jq -r '.token')
                """.stripIndent().trim()

                stage('Pre-flight Check') {
                    withAwsAuth(envName, img) {
                        sh """
                            ${fetchToken}
                            ./scripts/cluster-status.sh ${envName}
                        """
                    }
                }

                stage('Approve') {
                    input message: "Perform rolling update on ${envName}? All nodes will be replaced one at a time.", ok: 'Proceed'
                }

                stage('Rolling Update') {
                    def skipFlag = params.SKIP_TERRAFORM ? '--skip-terraform' : ''
                    withAwsAuth(envName, img) {
                        sh """
                            ${fetchToken}
                            echo 'yes' | ./scripts/rolling-update.sh ${envName} ${skipFlag}
                        """
                    }
                }

                stage('Post-update Health Check') {
                    withAwsAuth(envName, img) {
                        sh """
                            ${fetchToken}
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
