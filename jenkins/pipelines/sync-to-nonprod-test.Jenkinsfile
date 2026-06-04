// Vault Cluster - Sync nonprod data to nonprod-test (scripted pipeline)
// Vault addresses and tokens resolved by the sync script at runtime.

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
                        sh "./scripts/sync-to-nonprod-test.sh --yes"
                    }
                }

                stage('Verify') {
                    withAwsAuth('nonprod', img) {
                        sh "./scripts/cluster-status.sh nonprod-test"
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
