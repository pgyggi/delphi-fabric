const helper = require('./helper.js')
const eventHelper = require('./util/eventHub')
const logger = require('./util/logger').new('instantiate-chaincode')

//FIXED: UTC [endorser] simulateProposal -> ERRO 370 failed to invoke chaincode name:"lscc"  on transaction ec81adb6041b4b71dade56f0e9749e3dd2a2be2a63e0518ed75aa94c94f3d3fe, error: Error starting container: API error (500): {"message":"Could not attach to network delphiProject_default: context deadline exceeded"}: setting docker network instead of docker-compose --project-name

// "chaincodeName":"mycc",
// 		"chaincodeVersion":"v0",
// 		"args":["a","100","b","200"]
// set peers to 'undefined' to target all peers in channel
exports.instantiateChaincode = (
		channel, richPeers, chaincodeId, chaincodeVersion, args, client = channel._clientContext) => {
	logger.debug(
			{ channelName: channel.getName(), peersSize: richPeers.length, chaincodeId, chaincodeVersion, args })

	//Error: Verifying MSPs not found in the channel object, make sure "intialize()" is called first.
	const { eventWaitTime } = channel

	return channel.initialize().then(() => {
		logger.info('channel.initialize() success', channel.getOrganizations())
		const txId = client.newTransactionID()
		const Policy = require('fabric-client/lib/Policy')
		const { Role, OrganizationUnit, Identity } = Policy.IDENTITY_TYPE // TODO only option 'Role' has been implemented
		const roleType = 'member' //member|admin

		const policyTypes = [
			'signed-by', (key) => key.match(/^\d+\-of$/)
		]
		const request = {
			chaincodeId,
			chaincodeVersion,
			args,
			fcn: 'init',// fcn is 'init' in default: `fcn` : optional - String of the function to be called on the chaincode once instantiated (default 'init')
			txId,
			targets: richPeers// optional: if not set, targets will be channel.getPeers
			// , 'endorsement-policy': {
			// 	identities: [
			// 		{
			// 			[Role]: {
			// 				name: roleType,
			// 				mspId: ''
			// 			}
			// 		}],
			// 	policy: {}
			// }
			// 		`chaincodeType` : optional -- Type of chaincode ['golang', 'car', 'java'] (default 'golang')
		}
		const existSymptom = '(status: 500, message: chaincode exists'
		return channel.sendInstantiateProposal(request).
				then(helper.chaincodeProposalAdapter('instantiate', proposalResponse => {
					const { response } = proposalResponse
					if (response && response.status === 200) return true
					if (proposalResponse instanceof Error && proposalResponse.toString().includes(existSymptom)) {
						logger.warn('swallow when existence')
						return true
					}
					return false
				})).
				then(({ nextRequest }) => {
					//ehhhh... duplicated check for skipping
					const { proposalResponses } = nextRequest
					const existCounter = []
					for (let proposalResponse of proposalResponses) {
						if (proposalResponse instanceof Error && proposalResponse.toString().includes(existSymptom)) {
							existCounter.push(proposalResponse)
						}
					}
					if (existCounter.length === proposalResponses.length) {
						return Promise.resolve(proposalResponses)
					}

					const promises = []
					for (let peer of richPeers) {
						const eventHub = helper.bindEventHub(peer,client)
						const txPromise = eventHelper.txEventPromise(eventHub, { txId, eventWaitTime }, ({ tx, code }) => {
							logger.debug('newTxEvent', { tx, code })
							return { valid: code === 'VALID', interrupt: true }
						})
						promises.push(txPromise)
					}

					return channel.sendTransaction(nextRequest).then(() => {
						logger.info('channel.sendTransaction success')
						return Promise.all(promises)
					})
				})
	})
}



