// Vault Cluster - Rolling Update (scripted pipeline)
// Vault token resolved by the scripts at runtime.

def envName = env.JOB_NAME.split('/')[1]

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

                stage('Pre-flight Check') {
                    withAwsAuth(envName, img) {
                        sh "./scripts/cluster-status.sh ${envName}"
                    }
                }

                stage('Approve') {
                    input message: "Perform rolling update on ${envName}? All nodes will be replaced one at a time.", ok: 'Proceed'
                }

                stage('Rolling Update') {
                    def skipFlag = params.SKIP_TERRAFORM ? '--skip-terraform' : ''
                    withAwsAuth(envName, img) {
                        sh "./scripts/rolling-update.sh ${envName} ${skipFlag} --yes"
                    }
                }

                stage('Post-update Health Check') {
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
