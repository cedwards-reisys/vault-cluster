// Vault Cluster - Rekey Recovery Keys (scripted pipeline)
// Vault token resolved by the rekey script at runtime.

properties([
    parameters([
        choice(name: 'ENVIRONMENT', choices: ['nonprod-test', 'nonprod', 'prod'], description: 'Target environment')
    ])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                def clusterName = "vault-${params.ENVIRONMENT}"

                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                def vaultAddr = ''
                withAwsAuth(params.ENVIRONMENT, img) {
                    vaultAddr = sh(
                        script: "aws ssm get-parameter --name /${clusterName}/config/vault-url --query Parameter.Value --output text",
                        returnStdout: true
                    ).trim()
                }

                echo "Environment: ${params.ENVIRONMENT}"
                echo "Vault Address: ${vaultAddr}"
                echo ""
                echo "NOTE: This job initiates a recovery key rekey."
                echo "It requires existing recovery keys to authorize."

                stage('Approve') {
                    input message: "Rekey recovery keys for ${params.ENVIRONMENT}?", ok: 'Proceed'
                }

                stage('Rekey') {
                    withAwsAuth(params.ENVIRONMENT, img) {
                        sh "./scripts/rekey-recovery.sh ${params.ENVIRONMENT}"
                    }
                }

                echo "Recovery key rekey complete. Store the new keys using the store-credentials job."
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
