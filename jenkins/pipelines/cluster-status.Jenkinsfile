// Vault Cluster - Cluster Status (scripted pipeline)
// Vault token resolved by the status script at runtime.

def envName = env.JOB_NAME.split('/')[1]

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
                        sh "./scripts/cluster-status.sh ${envName}"
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
