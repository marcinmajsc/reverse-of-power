package com.game.remoteclient.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.navigation.fragment.findNavController
import androidx.recyclerview.widget.LinearLayoutManager
import com.game.protocol.ClientHoldingScreenCommandMessage
import com.game.protocol.RejoiningClientOwnProfileMessage
import com.game.remoteclient.BuildConfig
import com.game.remoteclient.GameRemoteClientApplication
import com.game.remoteclient.R
import com.game.remoteclient.databinding.FragmentServerDiscoveryBinding
import com.game.remoteclient.models.GameServer
import kotlinx.coroutines.launch

class ServerDiscoveryFragment : Fragment() {

    private var _binding: FragmentServerDiscoveryBinding? = null
    private val binding get() = _binding!!

    private val networkManager by lazy { GameRemoteClientApplication.getInstance().networkManager }
    private lateinit var serverAdapter: ServerAdapter

    private var manualEntryExpanded = false
    private var navigated = false

    private val rejoiningCallback: (RejoiningClientOwnProfileMessage) -> Unit = {
        navigateOnce(R.id.action_serverDiscovery_to_holdingScreen)
    }
    private val holdingScreenCallback: (ClientHoldingScreenCommandMessage) -> Unit = {
        navigateOnce(R.id.action_serverDiscovery_to_holdingScreen)
    }
    private val resetToNameEntryCallback: () -> Unit = {
        navigateOnce(R.id.action_serverDiscovery_to_nameEntry)
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        _binding = FragmentServerDiscoveryBinding.inflate(inflater, container, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        navigated = false
        setupRecyclerView()
        setupListeners()
        if (BuildConfig.DEBUG) {
            binding.ipAddressInput.setText("192.168.1.152")
        }
        startServerScan()
    }

    private fun setupRecyclerView() {
        serverAdapter = ServerAdapter { server ->
            onServerSelected(server)
        }

        binding.serversRecyclerView.apply {
            layoutManager = LinearLayoutManager(requireContext())
            adapter = serverAdapter
        }
    }

    private fun setupListeners() {
        binding.connectButton.setOnClickListener {
            val ipAddress = binding.ipAddressInput.text.toString().trim()
            if (ipAddress.isNotEmpty()) {
                val server = GameServer(ipAddress)
                onServerSelected(server)
            } else {
                Toast.makeText(requireContext(), getString(R.string.enter_ip_prompt), Toast.LENGTH_SHORT).show()
            }
        }

        binding.rescanButton.setOnClickListener {
            startServerScan()
        }

        if (BuildConfig.DEBUG) {
            binding.debugButton.visibility = View.VISIBLE
            binding.debugButton.setOnClickListener {
                findNavController().navigate(R.id.action_serverDiscovery_to_debugLauncher)
            }
        } else {
            binding.debugButton.visibility = View.GONE
        }

        binding.manualEntryHeader.setOnClickListener {
            manualEntryExpanded = !manualEntryExpanded
            binding.ipEntryCard.visibility = if (manualEntryExpanded) View.VISIBLE else View.GONE
            binding.expandIcon.rotation = if (manualEntryExpanded) 180f else 0f
        }
    }

    private fun startServerScan() {
        binding.scanningContainer.visibility = View.VISIBLE
        binding.noServersText.visibility = View.GONE
        binding.rescanButton.isEnabled = false
        serverAdapter.submitList(emptyList())

        lifecycleScope.launch {
            try {
                val servers = networkManager.scanForServers()
                if (_binding == null) return@launch
                binding.scanningContainer.visibility = View.GONE
                binding.rescanButton.isEnabled = true

                if (servers.isEmpty()) {
                    binding.noServersText.visibility = View.VISIBLE
                } else {
                    binding.noServersText.visibility = View.GONE
                    serverAdapter.submitList(servers)
                }
            } catch (e: Exception) {
                if (_binding == null) return@launch
                binding.scanningContainer.visibility = View.GONE
                binding.rescanButton.isEnabled = true
                binding.noServersText.visibility = View.VISIBLE
                Toast.makeText(requireContext(), getString(R.string.scan_failed, e.message), Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun setServerOptionsVisible(visible: Boolean) {
        val vis = if (visible) View.VISIBLE else View.GONE
        binding.serversRecyclerView.visibility = vis
        binding.manualEntryContainer.visibility = vis
        binding.rescanButton.visibility = vis
        binding.discoveredServersLabel.visibility = vis
        if (!visible) binding.noServersText.visibility = View.GONE
    }

    private fun onServerSelected(server: GameServer) {
        binding.connectButton.isEnabled = false
        binding.scanningContainer.visibility = View.VISIBLE
        binding.scanningText.text = getString(R.string.connecting_to_server)
        setServerOptionsVisible(false)

        // The handshake finishes asynchronously after the UDP connection acknowledgement.
        // Route each possible server state once its first game-state message arrives.
        networkManager.onRejoining = rejoiningCallback
        networkManager.onHoldingScreenMessage = holdingScreenCallback
        networkManager.onResetToNameEntryInterceptor = resetToNameEntryCallback

        lifecycleScope.launch {
            try {
                val success = networkManager.connectToServer(server)
                if (_binding == null) return@launch

                if (!success) {
                    binding.scanningContainer.visibility = View.GONE
                    binding.connectButton.isEnabled = true
                    setServerOptionsVisible(true)
                    clearCallbacks()
                    Toast.makeText(
                        requireContext(),
                        getString(R.string.failed_to_connect, server.fullAddress),
                        Toast.LENGTH_LONG
                    ).show()
                }
                // If success, wait for quiz command or holding screen callback to navigate
            } catch (e: Exception) {
                if (_binding == null) return@launch
                binding.scanningContainer.visibility = View.GONE
                binding.connectButton.isEnabled = true
                setServerOptionsVisible(true)
                clearCallbacks()
                Toast.makeText(
                    requireContext(),
                    getString(R.string.connection_error_detail, e.message),
                    Toast.LENGTH_LONG
                ).show()
            }
        }
    }

    private fun navigateOnce(actionId: Int) {
        activity?.runOnUiThread {
            if (_binding == null || navigated) return@runOnUiThread
            navigated = true
            clearCallbacks()
            findNavController().navigate(actionId)
        }
    }

    private fun clearCallbacks() {
        if (networkManager.onRejoining === rejoiningCallback) networkManager.onRejoining = null
        if (networkManager.onHoldingScreenMessage === holdingScreenCallback) {
            networkManager.onHoldingScreenMessage = null
        }
        if (networkManager.onResetToNameEntryInterceptor === resetToNameEntryCallback) {
            networkManager.onResetToNameEntryInterceptor = null
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        clearCallbacks()
        _binding = null
    }
}
