// Vault Cluster - Daily backup validation (scripted pipeline)
//
// Validates the most recent daily snapshot in S3 via
// `vault operator raft snapshot inspect`. Purely local — no Vault connection,
// no token required.
//
// Schedule: daily at 07:15 UTC (one hour after the 06:00 UTC backup window,
// gives the 15-minute jitter plenty of slack). Configure via Jenkins job UI
// using `properties([ pipelineTriggers([cron('15 7 * * *')]) ])` or the
// folder's multibranch/CRON settings.

def envName = env.JOB_NAME.split('/')[1]

properties([
    parameters([
        string(name: 'MAX_AGE_HOURS',  defaultValue: '8',     description: 'Freshness ceiling (hours)'),
        string(name: 'MIN_SIZE_BYTES', defaultValue: '10240', description: 'Minimum acceptable snapshot size (bytes)')
    ]),
    pipelineTriggers([cron('15 7 * * *')])
])

node {
    timestamps {
        ansiColor('xterm') {
            try {
                stage('Checkout') {
                    checkout scm
                }

                def img = buildVaultOpsImage()

                stage('Validate Backup') {
                    withAwsAuth(envName, img, "-e MAX_AGE_HOURS=${params.MAX_AGE_HOURS} -e MIN_SIZE_BYTES=${params.MIN_SIZE_BYTES}") {
                        sh "./scripts/validate-backup.sh ${envName}"
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
