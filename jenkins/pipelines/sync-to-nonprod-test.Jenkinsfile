// Vault Cluster - Sync nonprod data to nonprod-test (scripted pipeline)
// Vault tokens for both environments fetched from AWS Secrets Manager.

properties([
    parameters([
        booleanParam(name: 'CONFIRM', defaultValue: false, description: 'Check to confirm you want to overwrite nonprod-test data')
    ])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                if (!params.CONFIRM) {
                    error('You must check CONFIRM to proceed. This will overwrite all nonprod-test data.')
                }

                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                stage('Approve') {
                    input message: 'This will REPLACE all nonprod-test data with a copy of nonprod. Continue?', ok: 'Sync'
                }

                stage('Sync') {
                    // Both envs are in nonprod account — instance profile covers both
                    withAwsAuth('nonprod', img) {
                        sh """
                            export VAULT_NONPROD_ADDR='https://vault.nonprod.reisys.io'
                            export VAULT_TEST_ADDR='https://vault.nonprod-test.reisys.io'

                            export VAULT_NONPROD_TOKEN=\$(aws secretsmanager get-secret-value \
                                --region us-east-1 \
                                --secret-id vault-nonprod/vault/root-token \
                                --query SecretString --output text | jq -r '.token')

                            export VAULT_TEST_TOKEN=\$(aws secretsmanager get-secret-value \
                                --region us-east-1 \
                                --secret-id vault-nonprod-test/vault/root-token \
                                --query SecretString --output text | jq -r '.token')

                            ./scripts/sync-to-nonprod-test.sh --yes
                        """
                    }
                }

                stage('Verify') {
                    withAwsAuth('nonprod', img) {
                        sh """
                            export VAULT_TOKEN=\$(aws secretsmanager get-secret-value \
                                --region us-east-1 \
                                --secret-id vault-nonprod/vault/root-token \
                                --query SecretString --output text | jq -r '.token')

                            ./scripts/cluster-status.sh nonprod-test
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
